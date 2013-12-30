-- |
-- Copyright: (C) 2013 Amgen, Inc.
--
-- Interaction with an instance of R. The interface in this module allows for
-- instantiating an arbitrary number of concurrent R sessions, even though
-- currently the R library only allows for one global instance, for forward
-- compatibility.
--
-- This module is intended to be imported qualified.

{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE RecursiveDo #-}

module Language.R.Instance
  ( -- * The R monad
    R
  , Context
  , runR
  , unsafeRunR
  , context
  , Config(..)
  , defaultConfig
  -- * R instance creation
  , initialize
  , finalize
  -- * helpers
  , with
  , runInRThread
  , postToRThread
  ) where

import           Control.Monad.R.Class
import           Control.Concurrent.OSThread
import qualified Foreign.R as R
import qualified Foreign.R.Embedded as R
import qualified Foreign.R.Interface as R
import qualified Language.R as LR
import           Foreign.C.String

import Control.Applicative
import Control.Concurrent
    ( forkOS
    , forkIO
    , threadDelay
    , takeMVar
    , putMVar
    , newEmptyMVar
    , myThreadId
    , isCurrentThreadBound
    , ThreadId
    , newEmptyMVar
    , takeMVar
    , putMVar
    , killThread
    )
import Control.Concurrent.Chan ( readChan, newChan, writeChan, Chan )
import Control.Exception ( bracket, catch, SomeException, throwTo, finally )
import Control.Monad.Catch ( MonadCatch )
import Control.Monad.Reader

import Foreign
    ( Ptr
    , allocaArray
    , StablePtr
    , newStablePtr
    , deRefStablePtr
    , freeStablePtr
    )
import Foreign.C.Types ( CInt(..) )
import Foreign.Storable (Storable(..))
import System.Environment ( getProgName, lookupEnv )
import System.IO.Unsafe   ( unsafePerformIO )
import System.Process     ( readProcess )
import System.SetEnv
#ifdef H_ARCH_UNIX
import Control.Exception ( onException )
import System.IO ( hPutStrLn, stderr )
import System.Posix.Resource
#endif

-- | R execution context (/aka/ an initialization witness).
data Context = Context

-- | The 'R' monad, for sequencing actions interacting with a single instance of
-- the R interpreter, much as the 'IO' monad sequences actions interacting with
-- the real world. The 'R' monad embeds the 'IO' monad, so all 'IO' actions can
-- be lifted to 'R' actions.
newtype R a = R { unR :: ReaderT Context IO a }
  deriving (Monad, MonadIO, Functor, MonadCatch, Applicative)

instance MonadR R

-- | Run an R action from the IO monad, given a reference to an R instance (the
-- 'Context').
runR :: Context -> R a -> IO a
runR ctx m = runInRThread $ runReaderT (unR m) ctx

-- | Run an R action in the global R instance from the IO monad. This action is
-- unsafe because it provides no static guarantee that the R instance was indeed
-- initialized. It is a backdoor that should not normally be used.
unsafeRunR :: R a -> IO a
unsafeRunR m = runInRThread $ runReaderT (unR m) Context

-- | Ask for the execution context of the monad.
context :: R Context
context = R $ ask

-- | Configuration options for R runtime.
data Config = Config
    { configProgName :: Maybe String    -- ^ Program name. If 'Nothing' then
                                        -- value of 'getProgName' will be used.
    , configArgs     :: [String]        -- ^ Command-line arguments.
    }

defaultConfig :: Config
defaultConfig = Config Nothing ["--vanilla", "--silent"]

-- | Populate environment with @R_HOME@ variable if it does not exist.
populateEnv :: IO ()
populateEnv = do
    mh <- lookupEnv "R_HOME"
    when (mh == Nothing) $
      setEnv "R_HOME" =<< fmap (head . lines) (readProcess "R" ["-e","cat(R.home())","--quiet","--slave"] "")

-- | A static address that survives GHCi reloadings which indicates
-- whether R has been initialized.
foreign import ccall "missing_r.h &isRInitialized" isRInitializedPtr :: Ptr CInt

-- | Allocate and initialize a new array of elements.
newCArray :: Storable a
          => [a]                                  -- ^ Array elements
          -> (Ptr a -> IO r)                      -- ^ Continuation
          -> IO r
newCArray xs k =
    allocaArray (length xs) $ \ptr -> do
      zipWithM_ (pokeElemOff ptr) [0..] xs
      k ptr

-- | Create a new embedded instance of the R interpreter.
initialize :: Config
           -> IO Context
initialize Config{..} = do
    initialized <- fmap (==1) $ peek isRInitializedPtr
    (>> return Context) $ unless initialized $ mdo
      -- Grab addresses of R global variables
      LR.pokeRVariables
        ( R.globalEnv, R.baseEnv, R.nilValue, R.unboundValue, R.missingArg
        , R.rInteractive, R.rCStackLimit, R.rInputHandlers
        )
      startRThread eventLoopThread
      eventLoopThread <- forkIO $ forever $ do
        threadDelay 30000
#ifdef H_ARCH_WINDOWS
        runInRThread R.processEvents
#else
        runInRThread $
          R.processGUIEventsUnix LR.rInputHandlersPtr
#endif
      runInRThread $ do
        populateEnv
        args <- (:) <$> maybe getProgName return configProgName
                    <*> pure configArgs
        argv <- mapM newCString args
        let argc = length argv
        newCArray argv $ R.initEmbeddedR argc
        poke LR.rInteractive 0
        -- setting the stack limit seems to only be required in Windows
        poke LR.rCStackLimitPtr (-1)
        poke isRInitializedPtr 1

-- | Finalize R environment.
finalize :: IO ()
finalize = do
    runInRThread $ do
      R.endEmbeddedR 0
      peek interpreterChanPtr >>= freeStablePtr
      poke isRInitializedPtr 0
    stopRThread

-- | Properly acquire the R runtime, initializing R and ensuring that it is
-- finalized before returning.
with :: Config -- ^ R configuration options.
      -> IO a
      -> IO a
with cfg = bracket (initialize cfg) (const finalize) . const

-- | Starts the R thread.
startRThread :: ThreadId -> IO ()
startRThread eventLoopThread = do
#ifdef H_ARCH_UNIX
    setResourceLimit ResourceStackSize (ResourceLimits ResourceLimitUnknown ResourceLimitUnknown)
      `onException` (hPutStrLn stderr $
                       "Language.R.Interpreter: "
                       ++ "Oops, cannot set stack size limit. "
                       ++ "Maybe try setting in your shell: ulimit -s unlimited"
                    )
#endif
    chan <- newChan
    mv <- newEmptyMVar
    void $ forkOS $ do
      myOSThreadId >>= putMVar mv
      forever (join $ readChan chan) `finally` killThread eventLoopThread
    rOSThreadId <- takeMVar mv
    newStablePtr (rOSThreadId, chan) >>= poke interpreterChanPtr

-- | Posts a computation to perform in the interpreter thread.
--
-- Returns immediately without waiting for the action to be computed.
--
postToRThread :: IO () -> IO ()
postToRThread =
    postToRThread_ . (`catch` (const (return ()) :: SomeException -> IO ()))

-- | Like postToRThread_ but does not swallow exceptions thrown by the
-- computation.
postToRThread_ :: IO () -> IO ()
postToRThread_ action = do
    tid <- myOSThreadId
    isBound <- isCurrentThreadBound
    if tid == rOSThreadId && isBound
      then action
      else writeChan interpreterChan action
  where
    (rOSThreadId, interpreterChan) = unsafePerformIO $
      peek interpreterChanPtr >>= deRefStablePtr

-- | Evaluates a computation in the interpreter thread.
--
-- Waits until the computation is complete and returns back the result.
--
runInRThread :: IO a -> IO a
runInRThread action = do
    mv <- newEmptyMVar
    tid <- myThreadId
    postToRThread_ $
      (action >>= putMVar mv) `catch` (\e -> throwTo tid (e :: SomeException))
    takeMVar mv

-- | Stops the R thread.
stopRThread :: IO ()
stopRThread = postToRThread_ $ myThreadId >>= killThread

-- | A static address that survives GHCi reloadings.
foreign import ccall "missing_r.h &interpreterChan" interpreterChanPtr :: Ptr (StablePtr (OSThreadId,Chan (IO ())))