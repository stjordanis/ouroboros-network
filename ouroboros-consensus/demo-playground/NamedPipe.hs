{-# LANGUAGE PolyKinds           #-}
{-# LANGUAGE ScopedTypeVariables #-}
module NamedPipe (
  -- * Sending & receiving txs
    withTxPipe
  , withPipe
  , DataFlow(..)
  , NodeMapping((:==>:))
  ) where

import           Control.Exception (SomeException, bracket, catch)
import           Control.Monad (when)
import           Data.Semigroup ((<>))
import           System.Directory (removeFile)
import           System.IO
import           System.Posix.Files (createNamedPipe, otherReadMode,
                     otherWriteMode, ownerModes, unionFileModes)

import           Ouroboros.Network.Node (NodeId (..))


data NodeMapping src tgt = src :==>: tgt

data DataFlow =
     Upstream   (NodeMapping NodeId NodeId)
   | Downstream (NodeMapping NodeId NodeId)

-- | Creates two pipes, one for reading, one for writing. The 'DataFlow' input
-- type is there to make it easier to correctly specify the pipes so that
-- correct communication can occur.
withPipe :: DataFlow
         -> ((Handle, Handle) -> IO a)
         -> IO a
withPipe dataflow action = do
    let (readName, writeName) = mkNames
    bracket (do createNamedPipe readName  (unionFileModes ownerModes otherReadMode)
                    `catch` (\(_ :: SomeException) -> pure ())
                createNamedPipe writeName (unionFileModes ownerModes otherReadMode)
                    `catch` (\(_ :: SomeException) -> pure ())
                (,) <$> openFile readName   ReadWriteMode
                    <*> openFile writeName  ReadWriteMode
            ) (\(r,w) -> do
                hClose r
                hClose w
                -- Destroy the pipes
                removeFile readName
                  `catch` (\(_ :: SomeException) -> pure ())
                removeFile writeName
                  `catch` (\(_ :: SomeException) -> pure ())
                )
            action

    -- Creates the correct names for the read and write handles based on the
    -- topology (upstream vs downstream nodes).
  where
    mkNames :: (String, String)
    mkNames = case dataflow of
        Downstream (source :==>: destination) ->
            let [src,tgt] = map dashify [source, destination]
            in ( "upstream-"   <> src <> "-" <> tgt
               , "downstream-" <> src <> "-" <> tgt
               )
        Upstream   (source :==>: destination) ->
            let [src,tgt] = map dashify [source, destination]
            in ( "downstream-" <> src <> "-" <> tgt
               , "upstream-"   <> src <> "-" <> tgt
               )

-- | Given a 'NodeId', it dashifies it.
dashify :: NodeId -> String
dashify (CoreId n)  = "core-node-"  <> show n
dashify (RelayId n) = "relay-node-" <> show n

-- | Given a 'NodeId', it yields a predictable name which can be used to
-- read transactions out of band.
namedTxPipeFor :: NodeId -> String
namedTxPipeFor n = "ouroboros-" <> dashify n <> "-tx-pipe"

-- | Creates a unidirectional pipe for Tx transmission.
withTxPipe :: NodeId
           -> IOMode
           -> Bool
           -- ^ Whether or not to destroy the pipe at teardown.
           -> (Handle -> IO a)
           -> IO a
withTxPipe node ioMode destroyAfterUse action = do
    let pipeName = namedTxPipeFor node
    bracket (do createNamedPipe pipeName (unionFileModes ownerModes otherWriteMode)
                    `catch` (\(_ :: SomeException) -> pure ())
                openFile pipeName ioMode
            ) (\p -> do
                hClose p
                when destroyAfterUse $
                  -- Destroy the pipe
                  removeFile pipeName
                    `catch` (\(_ :: SomeException) -> pure ())
                )
            action
