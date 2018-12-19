module Ouroboros.Network.MuxWithDeltaQ
  (
  ) where

import qualified Data.String.Lazy as LS
import Numeric.Natural

import Ouroboros.Network.MonadClass.MonadSTM
  
-- | Desired servicing semantics
--   ===========================
--
--   Constructing fairness
--   ---------------------
--   In this context we are defining fairness as:
--    - no starvation
--    - when presented with equal demand (from a selection of mini
--      protocols) deliver "equal" service. 
--     
--   Equality here might be in terms of equal service rate of
--   requests (or segmented requests) and/or in terms of effective
--   (SDU) data rates.
--   
--
--  Notes: 
-- 
--   1) It is assumed that (for a given peer) that bulk delivery of
--      blocks (i.e. in recovery mode) and normal, interactive,
--      operation (e.g. chain following) are mutually exclusive. As
--      such there is no requirement to create a notion of
--      prioritisation between such traffic.
--
--   2) We are assuming that the underlying TCP/IP bearer is managed
--      so that indivual Mux-layer PDUs are paced. a) this is necessary
--      to mitigate head-of-line blocking effects (i.e. arbitrary
--      amounts of data accruing in the O/S kernel); b) ensuring that
--      any host egress data rate limits can be respected / enforced.
--       
--  Current Caveats
--
--  1) Not considering how mini-protocol associations are constructed
--     (depending on deployment model this might be resolved within
--     the instantiation of the peer relationship)
--
--  2) Not yet considered notion of orderly termination - this not
--     likely to be used in an operational context, but may be needed
--     for test harness use.
--
--  Principle of operation
--  ======================
--
--  Egress direction (mini protocol instance to remote peer)
--  --------------------------------------------------------
-- 
--  The request for service (the demand) from a mini protocol is
--  encapsulatedin a `Wanton`, such `Wanton`s are placed in a (finite)
--  queue (e.g TBMQ) of `TranslocationServiceRequest`s.
--
--
--  A `TranslocationServiceRequest` is a demand for the translocation
--  of a single mini-protocol message. This message can be of
--  arbitrary (yet bounded) size. This multiplexing layer is
--  responsible for the segmentation of concrete representation into
--  appropriate SDU's for onward transmission.

data TranslocationServiceRequest
  = TLSRDemand  { protocolIndex :: MuxProtocolIndex
                  demand        :: Wanton
                }
  | TLSRControl { protocolIndex :: MuxProtocolIndex
                  action        :: TLSRAction
                }

data TLSRAction = Abort | Done

-- The concrete index for a given mini-protocol
newtype MuxProtocolIndex = MuxPI Natural

-- The concrete data to be translocated, note that the TMVar becoming empty indicates
-- that the last fragment of the data has been enqueued on the
-- underlying bearer.

newtype Wanton = TMVar LS.ByteString

-- Each peer's multiplexer has some state that provides both
-- de-multiplexing details (for despatch of incoming mesages to mini
-- protocols) and for dispatching incoming SDUs.  This is shared
-- between the muxIngress and the bearerIngress processes.

data PerMuxSharedState = PerMuxSS
  {  dispatchTable  :: IntMap (TBQueue LS.ByteString) -- assumed
                       -- fixed, known at instantiation
  ,   maxSDU        :: Int -- asusumed known at time of instantiation
   -- handles to senders or pipes or whatever
   -- additional performance info (perhaps) 
  }

-- Process the messages from the mini protocols - there is a single
-- shared FIFO that contains the items of work. This is processed so
-- that each active demand gets a `maxSDU`s work of data processed
-- each time it gets to the front of the queue

muxIngressMiniProtocol :: (MonadSTM m)
                       => PerMuxSharedState
                       -> TBQueue TranslocationServiceRequest
                       -> m ()
muxIngressMiniProtocol pmss tbq
  = atomically (readTBQueue tbq) >>= \case
     TLSRDemand pi demand
        -> processSingleWanton pmss tbq pi demand >> muxIngressMiniProtocol pmss tbq
     TLSRControl pi act
        -> undefined

-- Pull a `maxSDU`s worth of data out out the `Wanton` - if there is
-- data remaining requeue the `TranslocationServiceRequest` (this
-- ensures that any other items on the queue will get some service
-- first.
processSingleWanton :: (MonadSTM m)
                    => PerMuxSharedState
                    -> TBQueue TranslocationServiceRequest
                    -> MuxProtocolIndex
                    -> Wanton
                    -> m ()
processSingleWanton pmss tbq mpi wanton = do
  sdu <- atomically $ do
    -- extract next SDU
    d <- fmap (maybe (fail "invalid State") id) $ tryTakeMVar wanton
    let (frag, rest) = splitAt (maxSDU pmss) d
    -- if more to process then enqueue remaining work
    unless (LS.null rest) $
      do putTMVar wanton rest
         writeTBQueue tbq (TLSRDemand mpi wanton)
    -- return data to send
    pure frag
  tNow <- forwardToPeer mpss mpi sdu
  paceTransmission mpss tNow
  
      


    
  
  
  
