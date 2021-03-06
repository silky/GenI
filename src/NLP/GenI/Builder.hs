-- GenI surface realiser
-- Copyright (C) 2005 Carlos Areces and Eric Kow
--
-- This program is free software; you can redistribute it and/or
-- modify it under the terms of the GNU General Public License
-- as published by the Free Software Foundation; either version 2
-- of the License, or (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program; if not, write to the Free Software
-- Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.

{-# LANGUAGE DeriveDataTypeable    #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}

{-|
The heavy lifting of GenI, the whole chart/agenda mechanism, can be
implemented in many ways.  To make it easier to write different
algorithms for GenI and compare them, we provide a single interface
for what we call Builders.

This interface is then used called by the Geni module and by the
graphical interface.  Note that each builder has its own graphical
interface and that we do a similar thing in the graphical interface
code to make it possible to use these GUIs.
-}

module NLP.GenI.Builder (
 TagDerivation, Builder(..), GenStatus(..),
 lexicalSelection, FilterStatus(..),incrCounter, num_iterations,
 (>-->),
 num_comparisons, chart_size,
 SemBitMap, defineSemanticBits, semToBitVector, bitVectorToSem, DispatchFilter, condFilter,
 defaultStepAll,
 BuilderState, UninflectedDisjunction(..), Input(..), unlessEmptySem,
 initStats, Output, SentenceAut, run, queryCounter, defaultMetricNames, preInit
)
where

import           Control.Monad.State.Strict
import           Data.Bits                  (bit, (.&.), (.|.))
import           Data.List                  (delete, nub, sort)
import qualified Data.Map                   as Map
import           Data.Maybe                 (fromMaybe, mapMaybe, maybeToList)
import           Data.Text                  (Text)
import qualified Data.Text                  as T
import           Data.Tree                  (flatten)
import           Prelude                    hiding (init)

import           Control.DeepSeq

import           Data.Generics              (Data)
import           Data.Typeable              (Typeable)

import           NLP.GenI.Automaton         (NFA, automatonPathSets,
                                             automatonPaths, numStates,
                                             numTransitions)
import           NLP.GenI.FeatureStructure  (Flist, mkFeatStruct, sortFlist)
import           NLP.GenI.Flag
import           NLP.GenI.General           (BitVector, geniBug, snd3, thd3)
import           NLP.GenI.GeniVal           (Collectable (collect),
                                             DescendGeniVal (..), GeniVal,
                                             finaliseVarsById)
import           NLP.GenI.Lexicon           (LexEntry)
import           NLP.GenI.Morphology.Types
import           NLP.GenI.Polarity          (PolResult (..), buildAutomaton,
                                             detectPolPaths)
import           NLP.GenI.Pretty
import           NLP.GenI.Semantics         (Literal, Sem, SemInput)
import           NLP.GenI.Statistics        (Metric (IntMetric), Statistics,
                                             addMetric, emptyStats,
                                             incrIntMetric, queryIntMetric,
                                             queryMetrics, updateMetrics)
import           NLP.GenI.Tag               (TagDerivation,
                                             TagElem (idname, tsemantics, ttree),
                                             dsChild, dsParent, setTidnums)
import           NLP.GenI.TreeSchema        (GNode (..), GType (Subs, Foot))

data GenStatus = Finished
               | Active
               | Error Text

data Builder st it = Builder
  { init     :: Input -> [Flag] -> (st, Statistics)
             -- ^ initialise the machine from the semantics and lexical selection
  , step     :: BuilderState st () -- ^ run a realisation step
  , stepAll  :: BuilderState st () -- ^ run all realisations steps until completion
  --
  , finished :: st -> GenStatus    -- ^ determine if realisation is finished
  , unpack   :: st -> [Output]     -- ^ unpack chart results into a list of sentences
  , partial  :: st -> [Output]
  }

type Output = (Integer, LemmaPlusSentence, TagDerivation)

-- | To simplify interaction with the backend, we provide a single data
--   structure which represents all the inputs a backend could take.

data Input =
  Input { inSemInput :: SemInput
        , inLex      :: [LexEntry] -- ^ for the debugger
        , inCands    :: [(TagElem, BitVector)]   -- ^ tag tree
        }

-- Uninflected words and sentences

-- | A SentenceAut represents a set of sentences in the form of an automaton.
--   The labels of the automaton are the words of the sentence.  But note!
--   “word“ in the sentence is in fact a tuple (lemma, inflectional feature
--   structures).  Normally, the states are defined as integers, with the
--   only requirement being that each one, naturally enough, is unique.
type SentenceAut            = NFA Int LemmaPlus

data UninflectedDisjunction = UninflectedDisjunction [Text] (Flist GeniVal) deriving (Data, Typeable)

instance DescendGeniVal UninflectedDisjunction where
  descendGeniVal s (UninflectedDisjunction a v) = {-# SCC "descendGeniVal" #-} UninflectedDisjunction a (descendGeniVal s v)

instance Collectable UninflectedDisjunction where
  collect (UninflectedDisjunction _ b) = collect b

-- BuilderState

-- To cleanly seperate the tracking of statistics from the core functionality of a
-- builder, we use a State transformer to thread a Statistics state monad inside of
-- our main monad.
type BuilderState s a = StateT s (State Statistics) a

-- ----------------------------------------------------------------------
-- Helper functions for Builders
-- ----------------------------------------------------------------------

-- Initialisation
--
-- There's a few things that need to be run before even initialising the builder.
-- One of these is running some of the optimisations (namely the polarity stuff),
-- which is made complicated by the fact that they are optional.  Another of these
-- to assign each of the trees with a unique ID.  Note that this has to be done
-- after the polarity optimisation because this optimisation may introduce new
-- items into the lexical selection.  Finally, we must also make sure we perform
-- alpha conversion so that unification does not do the wrong thing when two trees
-- have the same variables.

preInit :: Input -> [Flag] -> (Input, PolResult)
preInit input flags_ =
 let (cand,_) = unzip $ inCands input
     seminput = inSemInput input
     --
     extraPol = Map.empty
     polsToDetect = fromMaybe (error "there should be a default for --detect-pols")
                  $ getFlag DetectPolaritiesFlg flags_
     rootFeat = mkFeatStruct $ getListFlag RootFeatureFlg flags_
     -- do any optimisations
     isPol = hasOpt Polarised flags_
     -- polarity optimisation (if enabled)
     autstuff = buildAutomaton polsToDetect rootFeat extraPol seminput cand
     autpaths = map concat . automatonPathSets . prFinal $ autstuff
     combosPol = if isPol then autpaths else [considerHasSem cand]
     considerHasSem = filter (not . null . tsemantics)
     -- polarity automaton construction uses the zero literal semantic
     -- items, but it may be safer to filter them out now if we are not
     -- using it
     -- chart sharing optimisation
     (cands2, pathIds) = unzip $ detectPolPaths combosPol
     --
     fixate ts ps = zip (map finaliseVarsById $ setTidnums ts) ps
     input2 = input { inCands    = fixate cands2 pathIds
                    , inSemInput = (prSem autstuff, snd3 seminput, thd3 seminput) }
     -- note: autstuff is only useful for the graphical debugger
  in (input2, autstuff)

-- | Equivalent to 'id' unless the input contains an empty or uninstatiated
--   semantics
unlessEmptySem :: Input -> [Flag] -> a -> a
unlessEmptySem input _
    | null semanticsErr = id
    | otherwise         = error semanticsErr
  where
    (cands,_) = unzip $ inCands input
    nullSemCands   = [ idname t | t <- cands, (null.tsemantics) t ]
    unInstSemCands = [ idname t | t <- cands, not $ Map.null $ collect (tsemantics t) Map.empty ]
    nullSemErr     =
        "The following trees have a null semantics: " ++
         T.unpack (T.unwords nullSemCands)
    unInstSemErr   =
        "The following trees have an uninstantiated semantics: " ++
        T.unpack (T.unwords unInstSemCands)
    semanticsErr =
        (if null nullSemCands   then "" else nullSemErr ++ "\n") ++
        (if null unInstSemCands then "" else unInstSemErr)

-- ----------------------------------------------------------------------
-- Running a surface realiser
-- ----------------------------------------------------------------------

-- | Performs surface realisation from an input semantics and a lexical selection.
--
--   Statistics tracked
--
--    * pol_used_bundles - number of bundled paths through the polarity automaton.
--                         see 'NLP.GenI.Automaton.automatonPathSets'
--
--    * pol_used_paths - number of paths through the final automaton
--
--    * pol_seed_paths - number of paths through the seed automaton (i.e. with no polarities).
--                       This is normally just 1, unless you have multi-literal semantics
--
--    * pol_total_states - combined number of states in the all the polarity automata
--
--    * pol_total_tras - combined number of transitions in all polarity automata
--
--    * pol_max_states - number of states in the polarity automaton with the most states
--
--    * pol_total_tras - number of transitions in the polarity automata with the most transitions
--
--    * sem_literals    - number of literals in the input semantics
--
--    * lex_trees       - total number of lexically selected trees

--    * lex_foot_nodes  - total number of nodes of any sort in lexically selected trees
--
--    * lex_subst_nodes - total number of sustitution nodes in lexically selected trees
--
--    * lex_foot_nodes  - total number of foot nodes in lexically selected trees
--
--    * plex_...        - same as the lex_ equivalent, but after polarity filtering
run :: Builder st it -> Input -> [Flag] -> (st, Statistics)
run builder input flags_ =
  let -- 0 normalise the config
      flags = modifyFlag RootFeatureFlg sortFlist flags_
      -- 1 run the setup stuff
      (input2, autstuff) = preInit input flags
      auts = map snd3 (prIntermediate autstuff)
      -- 2 call the init stuff
      (iSt, iStats) = init builder input2 flags
      -- 2b extra statistics
      autpaths = map concat . automatonPathSets . prFinal $ autstuff
      countsFor ts = (length ts, length nodes, length sn, length an)
        where nodes = concatMap (flatten.ttree) ts
              sn = [ n | n <- nodes, gtype n == Subs  ]
              an = [ n | n <- nodes, gtype n == Foot  ]
      (tsem,_,_) = inSemInput input
      cands = nub . map fst $ inCands input
      cands2 = nub . concatMap concat . automatonPathSets . prFinal $ autstuff
      countUp = do incrCounter "sem_literals"  $ length tsem
                   --
                   incrCounter "lex_subst_nodes" snl
                   incrCounter "lex_foot_nodes"  anl
                   incrCounter "lex_nodes"        nl
                   incrCounter "lex_trees"        tl
                   -- node count after polarities are taken into account
                   incrCounter "plex_subst_nodes" snl2
                   incrCounter "plex_foot_nodes"  anl2
                   incrCounter "plex_nodes"        nl2
                   incrCounter "plex_trees"        tl2
                where (tl , nl , snl , anl ) = countsFor cands
                      (tl2, nl2, snl2, anl2) = countsFor cands2
      -- 3 step through the whole thing
      stepAll_ = do countUp
                    incrCounter "pol_used_bundles" $ length autpaths
                    incrCounter "pol_used_paths"   $ length . automatonPaths . prFinal   $ autstuff
                    incrCounter "pol_seed_paths"   $ length . automatonPaths . prInitial $ autstuff
                    incrCounter "pol_total_states" $ sum $ map numStates auts
                    incrCounter "pol_total_trans"  $ sum $ map numTransitions auts
                    incrCounter "pol_max_states"   $ maximum $ map numStates auts
                    incrCounter "pol_max_trans"    $ maximum $ map numTransitions auts
                    stepAll builder
  in runState (execStateT stepAll_ iSt) iStats

-- ----------------------------------------------------------------------
-- Semantics and bit vectors
-- ----------------------------------------------------------------------

type SemBitMap = Map.Map (Literal GeniVal) BitVector

-- | assign a bit vector value to each literal in the semantics
-- the resulting map can then be used to construct a bit vector
-- representation of the semantics
defineSemanticBits :: Sem -> SemBitMap
defineSemanticBits sem = Map.fromList $ zip sem bits
  where
   bits = map bit [0..] -- 0001, 0010, 0100...

semToBitVector :: SemBitMap -> Sem -> BitVector
semToBitVector bmap sem = foldr (.|.) 0 $ map doLookup sem
  where doLookup p =
         case Map.lookup p bmap of
         Nothing -> geniBug $ "predicate " ++ prettyStr p ++ " not found in semanticBit map"
         Just b  -> b

bitVectorToSem :: SemBitMap -> BitVector -> Sem
bitVectorToSem bmap vector =
  mapMaybe tryKey $ Map.toList bmap
  where tryKey (p,k) = if (k .&. vector == k) then Just p else Nothing

-- ----------------------------------------------------------------------
-- Generate step
-- ----------------------------------------------------------------------

-- | Default implementation for the 'stepAll' function in 'Builder'
defaultStepAll :: Builder st it -> BuilderState st ()
defaultStepAll b =
 do s <- get
    case finished b s of
      Active -> step b >> defaultStepAll b
      _      -> return ()

-- | Dispatching consists of assigning a chart item to the right part of the
--   chart (agenda, trash, results list, etc).  This is implemented as a
--   series of filters which can either fail or succeed.  If a filter fails,
--   it may modify the item before passing it on to future filters.
type DispatchFilter s a = a -> s (FilterStatus a)

data FilterStatus a = Filtered | NotFiltered a

-- | Sequence two dispatch filters.
(>-->) :: (Monad s) => DispatchFilter s a -> DispatchFilter s a -> DispatchFilter s a
f >--> f2 = \x -> f x >>= next
 where
  next y@Filtered = return y
  next (NotFiltered x2) = f2 x2

-- | If the item meets some condition, use the first filter, otherwise
--   use the second one.
condFilter :: (Monad s) => (a -> Bool)
           -> DispatchFilter s a -> DispatchFilter s a
           -> DispatchFilter s a
condFilter cond f1 f2 = \x -> if cond x then f1 x else f2 x

-- ----------------------------------------------------------------------
-- Statistics
-- ----------------------------------------------------------------------

modifyStats :: (Metric -> Metric) -> BuilderState st ()
modifyStats fn = lift $ modify $ updateMetrics fn

incrCounter :: String -> Int -> BuilderState st ()
incrCounter key n = modifyStats (incrIntMetric key n)

queryCounter :: String -> Statistics -> Maybe Int
queryCounter key s =
  case queryMetrics (queryIntMetric key) s of
  []  -> Nothing
  [c] -> Just c
  _   -> geniBug $ "More than one instance of the metric: " ++ key

-- Command line configuration

initStats :: [Flag] -> Statistics
initStats flags_ =
    execState (mapM_ addMetric metrics) emptyStats
  where
    mdefault ms = if "default" `elem` ms then defaultMetricNames else []
    identifyMs :: [String] -> [Metric]
    identifyMs ms = map namedMetric $ mdefault ms ++ delete "default" ms
    metrics = identifyMs $ fromMaybe [] $ getFlag MetricsFlg flags_

namedMetric :: String -> Metric
-- the default case is that it's an int metric
namedMetric n = IntMetric n 0

-- Note that the strings here are command-line strings, not metric names!
defaultMetricNames :: [ String ]
defaultMetricNames = [ num_iterations, chart_size, num_comparisons, gen_time ]

-- Common counters
--
-- These numbers allow us to keep track of how efficient our generator is
-- and where we are in the process (how many steps we've taken, etc)

num_iterations, chart_size, num_comparisons, gen_time :: String

num_iterations  = "iterations"
chart_size      = "chart_size"
num_comparisons = "comparisons"
gen_time = "gen_time"

-- ----------------------------------------------------------------------
-- pretty printing
-- ----------------------------------------------------------------------

instance Pretty GenStatus where
    pretty Finished  = "finished"
    pretty Active    = "in progress"
    pretty (Error x) = "error:" <+> x

-- ----------------------------------------------------------------------
-- strictly API-ish bits
-- ----------------------------------------------------------------------

-- | The names of lexically selected chart items used in a derivation
lexicalSelection :: TagDerivation -> [Text]
lexicalSelection = sort . nub
                 . concatMap (\d -> dsChild d : maybeToList (dsParent d))

{-!
deriving instance NFData Input
!-}

-- GENERATED START


instance NFData Input where
        rnf (Input x1 x2 x3) = rnf x1 `seq` rnf x2 `seq` rnf x3 `seq` ()

-- GENERATED STOP
