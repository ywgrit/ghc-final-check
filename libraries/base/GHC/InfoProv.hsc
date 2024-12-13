{-# LANGUAGE Trustworthy #-}
{-# LANGUAGE UnboxedTuples #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE NoImplicitPrelude #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  GHC.InfoProv
-- Copyright   :  (c) The University of Glasgow 2011
-- License     :  see libraries/base/LICENSE
--
-- Maintainer  :  cvs-ghc@haskell.org
-- Stability   :  internal
-- Portability :  non-portable (GHC Extensions)
--
-- Access to GHC's info-table provenance metadata.
--
-- @since 4.18.0.0
-----------------------------------------------------------------------------

module GHC.InfoProv
    ( InfoProv(..)
    , ipLoc
    , ipeProv
    , whereFrom
      -- * Internals
    , InfoProvEnt
    , peekInfoProv
    ) where

#include "Rts.h"

import GHC.Base
import GHC.Show
import GHC.Ptr (Ptr(..), plusPtr, nullPtr)
import GHC.Foreign (CString, peekCString)
import GHC.IO.Encoding (utf8)
import Foreign.Storable (peekByteOff)

data InfoProv = InfoProv {
  ipName :: String,
  ipDesc :: String,
  ipTyDesc :: String,
  ipLabel :: String,
  ipMod :: String,
  ipSrcFile :: String,
  ipSrcSpan :: String
} deriving (Eq, Show)

data InfoProvEnt

ipLoc :: InfoProv -> String
ipLoc ipe = ipSrcFile ipe ++ ":" ++ ipSrcSpan ipe

getIPE :: a -> IO (Ptr InfoProvEnt)
getIPE obj = IO $ \s ->
   case whereFrom## obj s of
     (## s', addr ##) -> (## s', Ptr addr ##)

ipeProv :: Ptr InfoProvEnt -> Ptr InfoProv
ipeProv p = (#ptr InfoProvEnt, prov) p

peekIpName, peekIpDesc, peekIpLabel, peekIpModule, peekIpSrcFile, peekIpSrcSpan, peekIpTyDesc :: Ptr InfoProv -> IO CString
peekIpName p    =  (# peek InfoProv, table_name) p
peekIpDesc p    =  (# peek InfoProv, closure_desc) p
peekIpLabel p   =  (# peek InfoProv, label) p
peekIpModule p  =  (# peek InfoProv, module) p
peekIpSrcFile p =  (# peek InfoProv, src_file) p
peekIpSrcSpan p =  (# peek InfoProv, src_span) p
peekIpTyDesc p  =  (# peek InfoProv, ty_desc) p

peekInfoProv :: Ptr InfoProv -> IO InfoProv
peekInfoProv infop = do
  name <- peekCString utf8 =<< peekIpName infop
  desc <- peekCString utf8 =<< peekIpDesc infop
  tyDesc <- peekCString utf8 =<< peekIpTyDesc infop
  label <- peekCString utf8 =<< peekIpLabel infop
  mod <- peekCString utf8 =<< peekIpModule infop
  file <- peekCString utf8 =<< peekIpSrcFile infop
  span <- peekCString utf8 =<< peekIpSrcSpan infop
  return InfoProv {
      ipName = name,
      ipDesc = desc,
      ipTyDesc = tyDesc,
      ipLabel = label,
      ipMod = mod,
      ipSrcFile = file,
      ipSrcSpan = span
    }

-- | Get information about where a value originated from.
-- This information is stored statically in a binary when `-finfo-table-map` is
-- enabled.  The source positions will be greatly improved by also enabled debug
-- information with `-g3`. Finally you can enable `-fdistinct-constructor-tables` to
-- get more precise information about data constructor allocations.
--
-- The information is collect by looking at the info table address of a specific closure and
-- then consulting a specially generated map (by `-finfo-table-map`) to find out where we think
-- the best source position to describe that info table arose from.
--
-- @since 4.16.0.0
whereFrom :: a -> IO (Maybe InfoProv)
whereFrom obj = do
  ipe <- getIPE obj
  -- The primop returns the null pointer in two situations at the moment
  -- 1. The lookup fails for whatever reason
  -- 2. -finfo-table-map is not enabled.
  -- It would be good to distinguish between these two cases somehow.
  if ipe == nullPtr
    then return Nothing
    else do
      infoProv <- peekInfoProv (ipeProv ipe)
      return $ Just infoProv
