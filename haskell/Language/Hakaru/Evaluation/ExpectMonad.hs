{-# LANGUAGE CPP
           , GADTs
           , KindSignatures
           , DataKinds
           , Rank2Types
           , ScopedTypeVariables
           , MultiParamTypeClasses
           , FlexibleContexts
           , FlexibleInstances
           #-}

{-# OPTIONS_GHC -Wall -fwarn-tabs #-}
----------------------------------------------------------------
--                                                    2016.04.05
-- |
-- Module      :  Language.Hakaru.Evaluation.ExpectMonad
-- Copyright   :  Copyright (c) 2016 the Hakaru team
-- License     :  BSD3
-- Maintainer  :  wren@community.haskell.org
-- Stability   :  experimental
-- Portability :  GHC-only
--
--
----------------------------------------------------------------
module Language.Hakaru.Evaluation.ExpectMonad
    ( pureEvaluate
    
    -- * The expectation-evaluation monad
    -- ** List-based version
    , ListContext(..), PureAns, Expect(..), runExpect
    -- ** TODO: IntMap-based version
    
    -- * ...
    , emit
    , emit_
    ) where

import           Prelude              hiding (id, (.))
import           Control.Category     (Category(..))
#if __GLASGOW_HASKELL__ < 710
import           Data.Functor         ((<$>))
import           Control.Applicative  (Applicative(..))
#endif
import qualified Data.Foldable        as F

import Language.Hakaru.Syntax.IClasses (Some2(..))
import Language.Hakaru.Syntax.ABT      (ABT(..), caseVarSyn, subst, maxNextFree)
import Language.Hakaru.Syntax.AST      hiding (Expect)
import Language.Hakaru.Evaluation.Types
import Language.Hakaru.Evaluation.Lazy (TermEvaluator, evaluate, defaultCaseEvaluator)
import Language.Hakaru.Evaluation.EvalMonad (ListContext(..), PureAns, residualizePureListContext)


-- The rest of these are just for the emit code, which isn't currently exported.
import           Data.Text             (Text)
import Language.Hakaru.Syntax.Variable (Variable())
import Language.Hakaru.Types.DataKind
import Language.Hakaru.Types.Sing      (Sing)
#ifdef __TRACE_DISINTEGRATE__
import Debug.Trace                     (trace)
#endif

----------------------------------------------------------------
----------------------------------------------------------------

newtype Expect abt x =
    Expect { unExpect :: (x -> PureAns abt 'HProb) -> PureAns abt 'HProb }


pureEvaluate :: (ABT Term abt) => TermEvaluator abt (Expect abt)
pureEvaluate = evaluate (brokenInvariant "perform") defaultCaseEvaluator

brokenInvariant :: String -> a
brokenInvariant loc = error (loc ++ ": Expect's invariant broken")


-- | Run a computation in the 'Expect' monad, residualizing out all the statements in the final evaluation context. The second argument should include all the terms altered by the 'Eval' expression; this is necessary to ensure proper hygiene; for example(s):
--
-- > runExpect (pureEvaluate e) [Some2 e]
--
-- We use 'Some2' on the inputs because it doesn't matter what their
-- type or locally-bound variables are, so we want to allow @f@ to
-- contain terms with different indices.
runExpect
    :: forall abt f a
    .  (ABT Term abt, F.Foldable f)
    => Expect abt (abt '[] a)
    -> abt '[a] 'HProb
    -> f (Some2 abt)
    -> abt '[] 'HProb
runExpect (Expect m) f es =
    m c0 h0
    where
    i0   = nextFree f `max` maxNextFree es
    h0   = ListContext i0 []
    c0 e =
        residualizePureListContext $
        caseVarSyn e
            (\x -> caseBind f $ \y f' -> subst y (var x) f')
            (\_ -> syn (Let_ :$ e :* f :* End))
        -- TODO: make this smarter still, to drop the let-binding entirely if it's not used in @f@.


----------------------------------------------------------------
instance Functor (Expect abt) where
    fmap f (Expect m) = Expect $ \c -> m (c . f)

instance Applicative (Expect abt) where
    pure x                  = Expect $ \c -> c x
    Expect mf <*> Expect mx = Expect $ \c -> mf $ \f -> mx $ \x -> c (f x)

instance Monad (Expect abt) where
    return         = pure
    Expect m >>= k = Expect $ \c -> m $ \x -> unExpect (k x) c

instance (ABT Term abt) => EvaluationMonad abt (Expect abt) 'Pure where
    freshNat =
        Expect $ \c (ListContext i ss) ->
            c i (ListContext (i+1) ss)

    unsafePush s =
        Expect $ \c (ListContext i ss) ->
            c () (ListContext i (s:ss))

    -- N.B., the use of 'reverse' is necessary so that the order
    -- of pushing matches that of 'pushes'
    unsafePushes ss =
        Expect $ \c (ListContext i ss') ->
            c () (ListContext i (reverse ss ++ ss'))

    select x p = loop []
        where
        -- TODO: use a DList to avoid reversing inside 'unsafePushes'
        loop ss = do
            ms <- unsafePop
            case ms of
                Nothing -> do
                    unsafePushes ss
                    return Nothing
                Just s  ->
                    -- Alas, @p@ will have to recheck 'isBoundBy'
                    -- in order to grab the 'Refl' proof we erased;
                    -- but there's nothing to be done for it.
                    case x `isBoundBy` s >> p s of
                    Nothing -> loop (s:ss)
                    Just mr -> do
                        r <- mr
                        unsafePushes ss
                        return (Just r)

-- TODO: make paremetric in the purity
-- | Not exported because we only need it for defining 'select' on 'Expect'.
unsafePop :: Expect abt (Maybe (Statement abt 'Pure))
unsafePop =
    Expect $ \c h@(ListContext i ss) ->
        case ss of
        []    -> c Nothing  h
        s:ss' -> c (Just s) (ListContext i ss')

----------------------------------------------------------------
emit
    :: (ABT Term abt)
    => Text
    -> Sing a
    -> (abt '[a] 'HProb -> abt '[] 'HProb)
    -> Expect abt (Variable a)
emit hint typ f = do
    x <- freshVar hint typ
    Expect $ \c h -> (f . bind x) $ c x h
    
emit_
    :: (ABT Term abt)
    => (abt '[] 'HProb -> abt '[] 'HProb)
    -> Expect abt ()
emit_ f = Expect $ \c h -> f $ c () h

----------------------------------------------------------------
----------------------------------------------------------- fin.