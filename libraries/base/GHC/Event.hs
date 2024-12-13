{-# LANGUAGE Trustworthy #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE CPP #-}

-- ----------------------------------------------------------------------------
-- | This module provides scalable event notification for file
-- descriptors and timeouts.
--
-- This module should be considered GHC internal.
--
-- ----------------------------------------------------------------------------

module GHC.Event
#if defined(javascript_HOST_ARCH)
    ( ) where
#else
    ( -- * Types
      EventManager
    , TimerManager

      -- * Creation
    , getSystemEventManager
    , new
    , getSystemTimerManager

      -- * Registering interest in I/O events
    , Event
    , evtRead
    , evtWrite
    , IOCallback
    , FdKey(keyFd)
    , Lifetime(..)
    , registerFd
    , unregisterFd
    , unregisterFd_
    , closeFd

      -- * Registering interest in timeout events
    , TimeoutCallback
    , TimeoutKey
    , registerTimeout
    , updateTimeout
    , unregisterTimeout
    ) where

import GHC.Event.Manager
import GHC.Event.TimerManager (TimeoutCallback, TimeoutKey, registerTimeout,
                               updateTimeout, unregisterTimeout, TimerManager)
import GHC.Event.Thread (getSystemEventManager, getSystemTimerManager)

#endif
