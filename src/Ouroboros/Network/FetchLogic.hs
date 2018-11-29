{-# LANGUAGE NamedFieldPuns             #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TupleSections              #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE StandaloneDeriving         #-}

module Ouroboros.Network.FetchLogic where

import           Data.Maybe
import           Data.Semigroup ((<>))
import qualified Data.Map.Strict as Map
import           Data.Map.Strict (Map)
import qualified Data.Dequeue as Q

import           Control.Monad
import           System.Random (Random(..), StdGen)

import           Ouroboros.Network.Block
import           Ouroboros.Network.Chain as Chain
import           Ouroboros.Network.MonadClass




{-
We have the node's /current/ or /adopted/ chain. This is the node's chain in
the sense specified by the Ouroboros algorithm. It is a fully verified chain
with block bodies and a ledger state.

    ┆   ┆
    ├───┤
    │   │
    ├───┤
    │   │
    ├───┤
    │   │
    ├───┤
    │   │
 ───┴───┴─── current chain length (block number)

With chain selection we are interested in /candidate/ chains. We have these
candidate chains in the form of chains of verified headers, but without bodies.

The consensus layer gives us the current set of candidate chains from our peers
and we have the task of selecting which block bodies to download, and then
passing those block bodes back to the consensus layer. The consensus layer will
try to validate them and decide if it wants to update its current chain.

    ┆   ┆     ┆   ┆     ┆   ┆     ┆   ┆     ┆   ┆
    ├───┤     ├───┤     ├───┤     ├───┤     ├───┤
    │   │     │   │     │   │     │   │     │   │
    ├───┤     ├───┤     ├───┤     ├───┤     ├───┤
    │   │     │   │     │   │     │   │     │   │
    ├───┤     ├───┤     ├───┤     ├───┤     ├───┤
    │   │     │   │     │   │     │   │     │   │
    ├───┤     ├───┤     ├───┤     ├───┤     └───┘
    │   │     │   │     │   │     │   │
 ───┴───┴─────┼───┼─────┼───┼─────┼───┼───────────── current chain length
              │   │     │   │     │   │
  current     ├───┤     ├───┤     └───┘
  (blocks)    │   │     │   │
              └───┘     └───┘
                A         B         C         D
             candidates
             (headers)

In this example we have four candidate chains, with all but chain D strictly
longer than our current chain.

In general there are many candidate chains. We make a distinction between a
candidate chain and the peer from which it is available. It is often the
case that the same chain is available from multiple peers. We will try to be
clear about when we are referring to chains or the combination of a chain and
the peer from which it is available.

For the sake of the example let us assume we have the four chains above
available from the following peers.

peer    1         2         3         4         5         6         7
      ┆   ┆     ┆   ┆     ┆   ┆     ┆   ┆     ┆   ┆     ┆   ┆     ┆   ┆
      ├───┤     ├───┤     ├───┤     ├───┤     ├───┤     ├───┤     ├───┤
      │   │     │   │     │   │     │   │     │   │     │   │     │   │
      ├───┤     ├───┤     ├───┤     ├───┤     └───┘     ├───┤     ├───┤
      │   │     │   │     │   │     │   │               │   │     │   │
    ──┼───┼─────┼───┼─────┼───┼─────┼───┼───────────────┼───┼─────┼───┼──
      │   │     │   │     │   │     │   │               │   │     │   │
      └───┘     ├───┤     ├───┤     ├───┤               ├───┤     ├───┤
                │   │     │   │     │   │               │   │     │   │
                └───┘     └───┘     └───┘               └───┘     └───┘
chain   C         A         B         A         D         B         A

This is the form in which we are informed about candidate chains from the
consensus layer, the combination of a chain and the peer it is from. This
makes sense, since these things change independently.

We will process the chains in this form, keeping the peer/chain combination all
the way through. Although there could in principle be some opportunistic saving
by sharing when multiple peers provide the same chain, taking advantage of this
adds complexity and does nothing to improve our worst case costs.

We are only interested in candidate chains that are strictly longer than our
current chain. So our first task is to filter down to this set.
-}

-- | Keep only those candidate chains that are strictly longer than a given
-- length (typically the length of the current adopted chain).
--
filterLongerCandidateChains :: HasHeader header
                            => BlockNo
                            -> [(Chain header, peer)]
                            -> [(Chain header, peer)]
filterLongerCandidateChains currentBlockNo =
    filter (\(c, _) -> Chain.headBlockNo c > currentBlockNo)

{-
In the example, this leaves us with only the candidate chains: A, B and C, but
still paired up with the various peers.


peer    1         2         3         4                   6         7
      ┆   ┆     ┆   ┆     ┆   ┆     ┆   ┆               ┆   ┆     ┆   ┆
      ├───┤     ├───┤     ├───┤     ├───┤               ├───┤     ├───┤
      │   │     │   │     │   │     │   │               │   │     │   │
      ├───┤     ├───┤     ├───┤     ├───┤               ├───┤     ├───┤
      │   │     │   │     │   │     │   │               │   │     │   │
    ──┼───┼─────┼───┼─────┼───┼─────┼───┼───────────────┼───┼─────┼───┼──
      │   │     │   │     │   │     │   │               │   │     │   │
      └───┘     ├───┤     ├───┤     ├───┤               ├───┤     ├───┤
                │   │     │   │     │   │               │   │     │   │
                └───┘     └───┘     └───┘               └───┘     └───┘
chain   C         A         B         A                   B         A


Of course we would at most need to download the blocks in a candidate chain
that are not already in the current chain. So we must find those intersections.

Before we do that, lets define how we represent a suffix of a chain. We
represent the range by two points: an exclusive lower bound and an inclusive
upper bound. Since the upper bound is the point at the head of the chain we
only need to remember the point at the lower and that defines the range
implicitly up to the end of the chain.

      ○   Start of range, exclusive
    ┌───┐
    │   │
    ├───┤
    │   │
    ├───┤
    │   │
    ├───┤
    │   │
    ├───┤
    │ ◉ │ End of range, inclusive.
    └───┘
-}

-- | A chain and a selected suffix. It is represented as a range between a
-- given point (exclusive) and the end of the chain (inclusive).
--
-- So for example the empty suffix has the point as the chain head.
--
data ChainSuffix header = ChainSuffix !(Chain header) !(Point header)

{-
We define the /fork range/ as the suffix of the candidate chain up until it
intersects the current chain.


   current    peer 1    peer 2

    ┆   ┆
    ├───┤
    │  ◀┿━━┓              ○
    ├───┤  ┃            ┌───┐
    │   │  ┗━━━━━━━━━━━━┿   │
    ├───┤               ├───┤
    │   │               │   │
    ├───┤               ├───┤
    │  ◀┿━━┓    ○       │   │
 ───┴───┴──╂──┬───┬─────┼───┼───
           ┗━━┿ ◉ │     │   │
              └───┘     ├───┤
                        │ ◉ │
                        └───┘
                C         A

In this example we found that C was a strict extension of the current chain
and chain A was a short fork.

We compute the suffix ranges by finding the intersection point and that becomes
the exclusive lower bound in the suffix representation.

Note that it's possible that we don't find any intersection within the last K
blocks. This means the candidate forks by more than K and so we are not
interested in this candidate at all.
-}

-- | Find the fork suffix range for a candidate chain, with respect to the
-- current chain.
--
chainForkSuffix :: HasHeader header
                => Chain header -- ^ Current chain.
                -> Chain header -- ^ Candidate chain
                -> Maybe (ChainSuffix header)
chainForkSuffix current candidate =
    --TODO: only interested in intersection within K blocks
    ChainSuffix candidate <$> Chain.intersectChains current candidate

chainsForkSuffix :: HasHeader header
                 => Chain header
                 -> [(Chain       header, peer)]
                 -> [(ChainSuffix header, peer)]
chainsForkSuffix current chains =
    catMaybes [ (,) <$> chainForkSuffix current chain <*> pure peer
              | (chain, peer) <- chains ]

{-
We define the /fetch range/ as the suffix of the fork range that has not yet
had its blocks downloaded and block content checked against the headers.

    ┆   ┆
    ├───┤
    │   │
    ├───┤               ┌───┐
    │   │    already    │   │
    ├───┤    fetched    ├───┤
    │   │    blocks     │ ○ │  ◄
    ├───┤               ├───┤
    │   │       ○   ◄   │░░░│  fetch range
 ───┴───┴─────┬───┬─────┼───┼───
              │░◉░│ ◄   │░░░│
              └───┘     ├───┤
                        │░◉░│  ◄
                        └───┘

We maintain and rely on the invariant that the ranges of fetched blocks are
backwards closed. This means we never have discontinuous ranges of fetched or
not-yet-fetched blocks.
-}

-- | Find the fetch suffix range of blocks that have not been fetched.
--
-- We rely on the invariant that the set of already downloaded blocks are
-- downward closed.
--
chainFetchSuffix :: HasHeader header
                 => (Point header -> Bool)
                 -> ChainSuffix header
                 -> ChainSuffix header
chainFetchSuffix alreadyDownloaded (ChainSuffix chain p) =
    case findBlock (alreadyDownloaded . blockPoint) chain of
      Nothing -> ChainSuffix chain p
      Just b  -> ChainSuffix chain (blockPoint b)

chainsFetchSuffix :: HasHeader header
                  => (Point header -> Bool)
                  -> [(ChainSuffix header, peer)]
                  -> [(ChainSuffix header, peer)]
chainsFetchSuffix alreadyDownloaded chains =
    [ (chainFetchSuffix alreadyDownloaded chainsuffix, peer)
    | (chainsuffix, peer) <- chains ]

{-
At this point we have all of the blocks we may be interested in downloading
from any peer. Decisions about downloading now depend on what we know about the
peers, such as the recent performance history and what requests we have
in-flight with that peer.

We split this into two phases. In the first phase we prioritise the chain/peer
pairs based on the chain fetch suffix and peer, but without considering what
is already in-flight. In the second phase we go through the chain/peer pairs
in order and now based on what is already in-flight we decide if it is time to
initiate any new block fetch requests.

The first phase is simply a re-ordering of the chain/peer pairs. For now we
can leave this as the identify and defer discussion on the policy.
-}

prioritisePeerChains :: HasHeader header
                     => [(ChainSuffix header, peer)]
                     -> [(ChainSuffix header, peer)]
prioritisePeerChains = id

{-
In the second phase we walk over the prioritised fetch suffixes for each peer
and make a decision about whether we should initiate any new fetch requests.

This decision is based on a number of factors:

 * Is the fetch suffix empty? If so, there's nothing to do.
 * Do we already have block fetch requests in flight with this peer?
 * If so are we under the maximum number of in-flight blocks for this peer?
 * Is this peer still performing within expectations or has it missed any soft
   time outs?
 * Has the peer missed any hard timeouts or otherwise been disconnected.
 * Are we at our soft or hard limit of the number of peers we are prepared to
   fetch blocks from concurrently?

We look at each peer chain fetch suffix one by one. Of course decisions we
make earlier can affect decisions later, in particular the number of peers we
fetch from concurrently can increase if we fetch from a new peer, and we must
obviously take that into account when considering later peer chains.
-}


type FetchDecision header peer = Either (FetchDecline header peer)
                                        (FetchRequest header peer)

data FetchRequest header peer = FetchRequest !peer !(ChainRange header)

-- | A range on a chain identified by two points. It is exclusive on the
-- lower end and inclusive on the upper end.
--
data ChainRange header = ChainRange !(Point header) !(Point header)

data FetchDecline header peer =
     FetchDeclineAllDownloaded  peer (Point header)
--   | FetchDeclineSlowPeer       peer
   | FetchDeclineInFlightLimit  peer Int
   | FetchDeclineConcLimitLimit peer Int

data FetchPolicyParams = FetchPolicyParams {
       deadlineSituation :: Bool,
       maxInFlightBlocksPerPeer :: Int,   --TODO: change to limit on bytes in flight
                                          -- with minimum of one block
                                          -- perhaps different in-flight data limits
                                          -- in deadline vs streaming situations
       maxConcurrentFetchPeers  :: Int
     }

data PeerFetchStatus header =
     FetchActive Int -- TimeoutState
   | FetchIdle

fetchRequestDecisions :: (HasHeader header, Ord peer)
                      => FetchPolicyParams
                      -> Map peer (PeerFetchStatus header)
                      -> [(ChainSuffix header, peer)]
                      -> [FetchDecision header peer]
fetchRequestDecisions fetchPolicyParams peersStatus =
    go (error "TODO") []
  where
    go _nConcurrentFetchPeers decisions [] = decisions
    go  nConcurrentFetchPeers decisions ((chain, peer) : cps) =

      let decision = fetchRequestDecision
                       fetchPolicyParams
                       nConcurrentFetchPeers
                       peerFetchStatus
                       chain
                       peer

          peerFetchStatus = peersStatus Map.! peer

          nConcurrentFetchPeers' =
            case (peerFetchStatus, decision) of
              (FetchIdle, Right _) -> nConcurrentFetchPeers + 1
              _                    -> nConcurrentFetchPeers

      in go nConcurrentFetchPeers' (decision:decisions) cps


fetchRequestDecision :: HasHeader header
                     => FetchPolicyParams
                     -> Int
                     -> PeerFetchStatus header
                     -> ChainSuffix header
                     -> peer
                     -> FetchDecision header peer
fetchRequestDecision FetchPolicyParams {
                       maxInFlightBlocksPerPeer,
                       maxConcurrentFetchPeers
                     }
                     nConcurrentFetchPeers
                     peerFetchStatus
                     (ChainSuffix chain point) peer
  | headPoint chain == point
  = Left (FetchDeclineAllDownloaded peer point)

{-
    -- TODO: need to decide how this recovers and how the timeout is updated
  | FetchActive _ _ TimeoutFired <- peerFetchStatus
  = Left (FetchDeclineSlowPeer peer)

--  | Just TimeoutCancelled <- mTimeoutState
--  = 
-}

  | FetchActive numInFlight <- peerFetchStatus
  , numInFlight >= maxInFlightBlocksPerPeer
  = Left (FetchDeclineInFlightLimit peer maxInFlightBlocksPerPeer)

  | FetchIdle <- peerFetchStatus
  , nConcurrentFetchPeers >= maxConcurrentFetchPeers
  = Left (FetchDeclineConcLimitLimit peer maxConcurrentFetchPeers)

  | otherwise
  = Right (FetchRequest peer fetchReqRange)
  where
    --TODO: limit the request range to fit within maxInFlightBlocksPerPeer
    fetchReqRange = ChainRange point (headPoint chain)

puttingItAllTogether :: (HasHeader header, Ord peer)
                     => FetchPolicyParams
                     -> (Point header -> Bool)
                     -> Map peer (PeerFetchStatus header)
                     -> Chain header
                     -> [(Chain header, peer)]
                     -> [FetchDecision header peer]
puttingItAllTogether fetchPolicyParams alreadyDownloaded peersStatus
                     currentChain =
    fetchRequestDecisions fetchPolicyParams peersStatus
  . prioritisePeerChains
  . chainsFetchSuffix alreadyDownloaded
  . chainsForkSuffix currentChain
  . filterLongerCandidateChains (headBlockNo currentChain)


{-- 

-- | Given a set of chains, and which peer they are from, select an order of
-- preference for downloading from them.
--
selectChainInstances :: forall header peer.
                        (HasHeader header, Ord peer)
                     => [(Chain header, peer)] -- ^ Candidate header chains
                     -> BlockNo                -- ^ Current chain length
                     -> (peer -> DeltaQ)
                     -> Duration               -- ^ Deadline, from now.
                     -> [(Chain header, peer)]
selectChainInstances candidateChains 

-- We start with a bunch of candidate chains, and where they come from.
-- In general we'll have the same chain from multiple peers.
--
-- peer   1   2   3   4   5   6   7
--       +-+ +-+ +-+ +-+ +-+ +-+ +-+
--      _|_|_|_|_|_|_|_|_|D|_| |_|_|__ current chain length
--       |_| |C| |_| |_| +-+ |_| |_|
-- chain |A| +-+ |B| |A|     |B| |A|
--       +-+     +-+ +-+     +-+ +-+
--
-- So in this example we have two longest chains, A and B. Chain A is available
-- from three peers, and chain B is available from two. We could also be
-- interested in chain C, which is longer than the current adopted chain, but
-- is not the longest candidate chain, since it may turn out that we cannot
-- download all of A or B.
--
-- We may still be interested in the shorter chains such as C, or even ones 
-- that are not longer than our current one such as D, if they share blocks
-- with a chain that we are interested in, as that provides an alternative
-- source from which to download some of the blocks.

-- First we select the chains that are strictly longer than the current one.
--
-- In the example that's chains A, B, C (but not D)

  let chainsOfInterest = [ (chain, peer)
                         | (chain, peer) <- candidateChains
                         , headBlockNo chain > currentBlockNo ]

-- If there are no chains we're interested in downloading we can just wait for
-- longer candidates to arrive.
  check (not (null chainsOfInterest))

-- TODO: if our own chain is of equal or better length then we don't have to
-- download anything, but we may actually still be interested if we've got
-- some interesting fork of equal length that we may want to pre-emptively
-- download and cache.

-- Set up a mapping, of chains of interest to the set of peers from which they
-- are available
--
-- In the example above that would be:
--
-- A -> {1,4,7}
-- B -> {3,6}
-- C -> {2}

  let chainSources :: Map (Point header) peer
      chainSources = Map.fromListWith (++)
                       [ (headPoint chain, [peer])
                       | (chain, peer) <- chainsOfInterest ]

-- If we're in a deadline situation then we are not interested in choices that
-- are not likely to arrive within our deadline. So our first choices are
-- chains that are the longest and their ETA (based on DeltaQ models) is within
-- the deadline. Our second choices are chains that are not the longest, but
-- are longer than the current chain and their ETA is within the deadline.
-- Finally, last choice is chains with an ETA outside of the deadline.
--
-- For our running example, the sake of argument suppose we know that peers
-- 6 and 7 have terrible performance (perhaps they're a long way away, or are
-- overloaded), then we would divide the peers into three groups, and within
-- each group organise them by chain and then perhaps pseudorandomly weighted
-- by some measure to spread out load.
--
--
-- Chain   A   B   C
--        ___________
--
-- Peers   1   3        Longest chains, ETA within deadline
--         4
--        ___________
--
--                 2    Longer than current chains, ETA within deadline
--        ___________
--
--         7   6        All other chains, ETA not within deadline
--
--
-- Now within the major groups we want to fall back to alternative chains
-- before falling back to alternative sources for the same chain, since this
-- policy mitigates some potential attacks.
--
-- So the overall order of preference is to transpose and concatenate, giving
-- the peer preference order of:
--
-- 1 3 4 2 7 6
--
--
-}

-- Invariant: no gaps in downloaded chains, so no splitting between peers


{-
We start with a bunch of candidate chains, and where they come from.
In general we'll have the same chain from multiple peers.

peer    1     2     3     4     5     6     7
      ┌───┐ ┌───┐ ┌───┐ ┌───┐ ┌───┐ ┌───┐ ┌───┐
      │   │ │   │ │   │ │   │ │   │ │   │ │   │ 
    ──┼───┼─┼───┼─┼───┼─┼───┼─┴───┴─┼───┼─┼───┼──   current chain length
      │   │ │   │ │   │ │   │       │   │ │   │
      ├───┤ └───┘ ├───┤ ├───┤       ├───┤ ├───┤
      │   │       │   │ │   │       │   │ │   │
      └───┘       └───┘ └───┘       └───┘ └───┘
chain   A     C     B     A     D     B     A



-- So in this example we have two longest chains, A and B. Chain A is available
-- from three peers, and chain B is available from two. We could also be
-- interested in chain C, which is longer than the current adopted chain, but
-- is not the longest candidate chain, since it may turn out that we cannot
-- download all of A or B.
--
-- We may still be interested in the shorter chains such as C, or even ones 
-- that are not longer than our current one such as D, if they share blocks
-- with a chain that we are interested in, as that provides an alternative
-- source from which to download some of the blocks.



    ┆   ┆
    ├───┤
    │  ◀┿━━┓
    ├───┤  ┃  ┌───┐
    │   │  ┗━━┿   │
    ├───┤     ├───┤
    │   │     │   │
    ├───┤     ├───┤
    │   │     │   │
 ───┴───┴─────┼───┼────
              │   │
              └───┘


    ┆   ┆     ┆   ┆     ┆   ┆     ┆   ┆
    ├───┤     ├───┤     ├───┤     ├───┤
    │   │     │   │     │   │     │   │
    ├───┤     ├───┤     ├───┤     ├───┤
    │   │     │   │     │   │     │   │
    ├───┤     ├───┤     ├───┤     ├───┤
    │   │     │   │     │   │     │   │
    ├───┤     ├───┤     ├───┤     ├───┤
    │   │     │   │     │   │     │   │
 ───┴───┴─────┼───┼─────┼───┼─────┼───┼───
   current/   │   │     │   │     │   │
   adopted    └───┘     ├───┤     ├───┤
 (full blocks)          │   │     │   │
                        └───┘     └───┘
                A         B   candidates (headers only)

Fetch range: the suffix of the fork range that has not yet been downloaded
In flight range: the range(s) of the fork range that have outstanding/in-flight
                 download requests (there can be multiple from different peers)
Request range: a suffix range for a particular peer, within the fetch range

-}




-- need function to compute range needed in new chain, intersect with current
-- chain.



data FetchRequestMsg  block = FetchRequestMsg (ChainRange block)
data FetchResponseMsg block = FetchResponseMsgBlock block
                            | FetchResponseMsgDone
                            | FetchResponseMsgFail


blockServer :: forall m block.
               (MonadTimer m, MonadSTM m)
            => StdGen
            -> Chain block
            -> TMVar m (FetchRequestMsg block)
            -> TMVar m (FetchResponseMsg block)
            -> m ()
blockServer prng0 chain inQ outQ =
    atomically (newTVar prng0) >>= forever . serve
  where
    serve prngVar = do
      FetchRequestMsg range <- recvMsg
      threadDelay . fromIntegral =<< randomUniform prngVar (1000, 100000)
      case selectRange chain range of
        Just blocks -> do mapM_ (sendMsg . FetchResponseMsgBlock) blocks
                          sendMsg FetchResponseMsgDone
        Nothing     -> sendMsg FetchResponseMsgFail

    recvMsg :: m (FetchRequestMsg block)
    recvMsg = atomically $ takeTMVar inQ

    sendMsg :: FetchResponseMsg block -> m ()
    sendMsg = atomically . putTMVar outQ

    randomUniform :: TVar m StdGen -> (Int, Int) -> m Int
    randomUniform prngVar range = atomically $ do
      prng <- readTVar prngVar
      let (wait, prng') = randomR range prng
      writeTVar prngVar prng'
      return wait

selectRange :: Chain block -> ChainRange block -> Maybe [block]
selectRange = undefined


data Distribution n = Distribution n
-- This is a totally bogus representation. It's just a PoC.
-- This says that there's a single value that it takes with probability 1.

instance Num n => Semigroup (Distribution n) where
  (<>) = convolveDistribution

convolveDistribution :: Num n => Distribution n -> Distribution n -> Distribution n
convolveDistribution (Distribution d) (Distribution d') = Distribution (d+d')
-- Again, totally bogus.

shiftDistribution :: Num n => n -> Distribution n -> Distribution n
shiftDistribution n (Distribution d) = Distribution (n+d)
-- Again, totally bogus.

data GSV t = GSV (Duration t)                -- G as seconds
                 (Duration t)                -- S as seconds / octet
                 (Distribution (Duration t)) -- V as distribution

instance TimeMeasure t => Semigroup (GSV t) where
  GSV g1 s1 v1 <> GSV g2 s2 v2 = GSV (g1+g2) (s1+s2) (v1 <> v2)

newtype DeltaQ t = DeltaQ (Distribution (Duration t))

deriving instance TimeMeasure t => Semigroup (DeltaQ t)

type Size = Word

gsvLeadingEdgeArrive  :: TimeMeasure t => GSV t ->         DeltaQ t
gsvTrailingEdgeDepart :: TimeMeasure t => GSV t -> Size -> DeltaQ t  -- perhaps a bit dubious
gsvTrailingEdgeArrive :: TimeMeasure t => GSV t -> Size -> DeltaQ t

gsvLeadingEdgeArrive (GSV g _s v) =
  DeltaQ (shiftDistribution g v)

gsvTrailingEdgeDepart (GSV _g s v) bytes =
  DeltaQ (shiftDistribution (s * fromIntegral bytes) v)

gsvTrailingEdgeArrive (GSV g s v) bytes =
  DeltaQ (shiftDistribution (g + s * fromIntegral bytes) v)


estimateDetltaQ99thPercentile :: DeltaQ t -> Duration t
estimateDetltaQ99thPercentile (DeltaQ (Distribution t)) = t
-- Again, totally bogus.

estimateProbabilityMassBeforeDeadline :: TimeMeasure t
                                      => DeltaQ t -> Duration t -> Double
estimateProbabilityMassBeforeDeadline (DeltaQ (Distribution t)) d
  | t < d     = 1
  | otherwise = 0
  -- Again, totally bogus.


{-
blockArrivalShedule :: TimeMeasure time
                    => (block -> Size)
                    -> GSV
                    -> time
                    -> [block]
                    -> [(Point block, time)]
blockArrivalShedule blockSize deltaq now blocks =
    [ (blockPoint b, eta)
    | b <- blocks
    , let eta = estimateETA deltaq (blockSize b) `addTime` now
    ]
-}

{-
submitFetchReqs :: ChainRange block
                -> [(Point block, time)]
                -> FetchTrackingState
                -> TMVar m (FetchRequestMsg block)
                -> m ()
submitFetchReqs range etaschedule FetchTrackingState{..} outQ =
    atomically $ do
      putTMVar outQ (FetchRequestMsg range)
      mapM_ (writeTBQueue blocksInFlight) etaschedule
      modifyTVar' bytesInFlight (+ sum (map (blockSize . fst) etaschedule))
-}


--  If I were to send this request now, when would the leading and trailing
-- edges of the response come back?
--
-- The leading edge is useful for setting a timeout to give us early indication
-- that we're highly likely to miss our response time. The trailing edge is
-- the time we are ultimately interested in, and a timeout on that ensures we
-- are not waiting too long before re-evaluating our decisions.
--
    -- Obviously the response times depend not just on the outbound and inbound
    -- Delta Qs, and the request and response sizes, but it also depends on
    -- the requests that the remote end is already processing.
    --
    -- We could keep track of the detail of the queue on the remote side, but
    -- this quickly gets complicated. Instead we make the following simplifying
    -- and conservative assumption. We only keep track of the amount of data
    -- we have requested that we have not yet received, and we pretend that we
    -- are now asking for that plus the new data we're really asking for.
    --
    -- This over-estimates the response time, but by at most one round trip.
    -- To see that this is the case, consider the most extreme case of response
    -- data that it just arriving at the receiver. If instead the leading edge
    -- is back at the initial request, that is a full round trip away. Note
    -- that to limit this to one round trip we need to update the in-flight
    -- data as it arrives, not just at the trailing edge of block messages.

data FetchTrackingState header time = FetchTrackingState {
       fetchRequestsInFlight      :: Queue (FetchRequestBatch header time),
       fetchRequestsBytesInFlight :: Size
     }

type Queue = Q.BankersDequeue

data FetchRequestBatch header time =
     FetchRequestBatch
       !(ChainRange header)         -- the requested range
       !time                        -- leading edge timeout
       [(BlockInfo header, time)]   -- blocks and trailing edge timeouts

data BlockInfo header = BlockInfo !(Point header) !Size



estimateBlockFetchResponse :: TimeMeasure time
                           => GSV time
                           -> GSV time
                           -> FetchTrackingState header time
                           -> [BlockInfo header]
                           -> Duration time
estimateBlockFetchResponse outboundGSV inboundGSV
                           FetchTrackingState{fetchRequestsBytesInFlight}
                           blocks =
    estimateDetltaQ99thPercentile $
         gsvTrailingEdgeArrive outboundGSV reqSize
      <> gsvTrailingEdgeArrive inboundGSV  rspSize
  where
    reqSize = 100 -- not exact, but it's small
    rspSize = fetchRequestsBytesInFlight
            + sum [ size | BlockInfo _ size <- blocks ]

blockArrivalShedule :: TimeMeasure time
                    => GSV time
                    -> GSV time
                    -> FetchTrackingState header time
                    -> [BlockInfo header]
                    -> (Duration time, [Duration time])
blockArrivalShedule outboundGSV inboundGSV
                    FetchTrackingState{fetchRequestsBytesInFlight}
                    blocks =
    ( batchLeadingEdgeArrival, blockTrailingEdgesArrival )
  where
    reqSize = 100 -- not exact, but it's small

    batchLeadingEdgeArrival =
        estimateDetltaQ99thPercentile $
             gsvTrailingEdgeArrive outboundGSV reqSize
          <> gsvTrailingEdgeArrive inboundGSV  fetchRequestsBytesInFlight

    blockTrailingEdgesArrival =
      [ estimateDetltaQ99thPercentile $
             gsvTrailingEdgeArrive outboundGSV reqSize
          <> gsvTrailingEdgeArrive inboundGSV  rspSize
      | rspSize <- cumulativeSumFrom fetchRequestsBytesInFlight
                                     [ size | BlockInfo _ size <- blocks ]
      ]
{-
    batchTrailingEdgeDeparture =
        estimateDetltaQ99thPercentile $
             gsvTrailingEdgeArrive outboundGSV reqSize
          <> gsvTrailingEdgeDepart inboundGSV  rspSize
      where
        rspSize = fetchRequestsBytesInFlight + sum (map snd reqblocks)
-}

    cumulativeSumFrom n = tail . scanl (+) n

{-
newFetchRequestBatch now fetchRange fetchBlocks =
    FetchRequestBatch
      fetchRange
      (addTime leadingEdge now)
      [ (block, addTime duration now)
      | (block, trailingEdge) <- zip fetchBlocks blockTrailingEdges ]
  where
    (leadingEdge, blockTrailingEdges) =
      blockArrivalShedule outboundGSV inboundGSV
                          fetchTrackingState
                          fetchBlocks
-}

{-
updateForNewRequest :: DeltaQ
                    -> DeltaQ
                    -> time
                    -> BlockInfo
                    -> FetchTrackingState
                    -> FetchTrackingState
updateForNewRequest outboundDeltaQ inboundDeltaQ now RemoteIdle =
    RemoteActive {
      _ = 
      _ =
      _ = Q.empty
    }
  where
    -- Point in time where our request would arrive on the remote side.
    est1 = estimateTrailingEdgeArrive outboundDeltaQ 100

    -- Point in time where the response would 
    est2 = estimateTrailingEdgeArrive inboundDeltaQ (blockSize b)

    est3 = estimateTrailingEdgeDepart inboundDeltaQ (blockSize b)


updateForNewRequest RemoteActive{..} =

updateForBlockArrival :: Point
                      -> FetchTrackingState
                      -> FetchTrackingState
-- 
-}
