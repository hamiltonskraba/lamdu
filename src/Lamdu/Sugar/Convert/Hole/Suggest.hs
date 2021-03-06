{-# LANGUAGE TypeFamilies, FlexibleContexts #-}
module Lamdu.Sugar.Convert.Hole.Suggest
    ( forType
    , termTransforms
    , termTransformsWithModify
    ) where

import           AST (Tree, monoChildren)
import           AST.Knot.Ann (Ann(..), ann, val, annotations)
import           AST.Infer
import           AST.Term.FuncType
import           AST.Term.Nominal
import           AST.Term.Row (RowExtend(..))
import           AST.Unify
import           AST.Unify.Binding (UVar)
import           AST.Unify.Term
import           Control.Applicative (Alternative(..))
import qualified Control.Lens as Lens
import           Control.Monad.State (StateT)
import qualified Control.Monad.State as State
import           Lamdu.Calc.Infer (PureInfer, InferState, runPureInfer)
import qualified Lamdu.Calc.Lens as ExprLens
import qualified Lamdu.Calc.Term as V
import qualified Lamdu.Calc.Type as T

import           Lamdu.Prelude

type UType m = Tree (UVarOf m) T.Type
type URow m = Tree (UVarOf m) T.Row

-- | Term with unifiable type annotations
type TypedTerm m = Tree (Ann (UType m)) V.Term

type AnnotatedTerm a = Tree (Ann (a, IResult UVar V.Term)) V.Term

-- | These are offered in fragments (not holes). They transform a term
-- by wrapping it in a larger term where it appears once.
termTransforms ::
    a -> AnnotatedTerm a ->
    StateT InferState [] (AnnotatedTerm a)
termTransforms def src =
    src ^. ann . _2 . irType & semiPruneLookup & liftInfer (src ^. ann . _2 . irScope)
    <&> (^? _2 . _UTerm . uBody . T._TRecord)
    >>=
    \case
    Just row | Lens.nullOf (val . V._BRecExtend) src ->
        transformGetFields def src row
    _ -> termTransformsWithoutSplit def src

transformGetFields ::
    a -> AnnotatedTerm a -> Tree UVar T.Row ->
    StateT InferState [] (AnnotatedTerm a)
transformGetFields def src row =
    semiPruneLookup row & liftInfer (src ^. ann . _2 . irScope)
    <&> (^? _2 . _UTerm . uBody . T._RExtend)
    >>=
    \case
    Nothing -> empty
    Just (RowExtend tag typ rest) ->
        pure (Ann (def, IResult typ (src ^. ann . _2 . irScope)) (V.BGetField (V.GetField src tag)))
        <|> transformGetFields def src rest

liftInfer :: Tree V.Scope UVar -> PureInfer a -> StateT InferState [] a
liftInfer scope act =
    do
        s <- State.get
        case runPureInfer scope s act of
            Left{} -> empty
            Right (r, newState) -> r <$ State.put newState

termTransformsWithoutSplit ::
    a -> AnnotatedTerm a -> StateT InferState [] (AnnotatedTerm a)
termTransformsWithoutSplit def src =
    do
        -- Don't modify a redex from the outside.
        -- Such transform are more suitable in it!
        Lens.nullOf (val . V._BApp . V.applyFunc . val . V._BLam) src & guard

        (s1, typ) <- src ^. ann . _2 . irType & semiPruneLookup & liftInfer srcScope
        case typ ^? _UTerm . uBody of
            Just (T.TInst (NominalInst name _params))
                | Lens.nullOf (val . V._BToNom) src ->
                    do
                        (fromNomTyp, _) <- V.LFromNom name & V.BLeaf & inferBody
                        resultType <- newUnbound
                        _ <- FuncType s1 resultType & T.TFun & newTerm >>= unify fromNomTyp
                        V.Apply (mkResult fromNomTyp (V.BLeaf (V.LFromNom name))) src
                            & V.BApp & mkResult resultType & pure
                    & liftInfer srcScope
                    >>= termOptionalTransformsWithoutSplit def
            Just (T.TVariant row) | Lens.nullOf (val . V._BInject) src ->
                do
                    dstType <- newUnbound
                    caseType <- FuncType s1 dstType & T.TFun & newTerm
                    suggestCaseWith row dstType
                        <&> Ann caseType
                        <&> annotations %~ (\t -> (def, IResult t srcScope))
                        <&> (`V.Apply` src) <&> V.BApp <&> mkResult dstType
                & liftInfer srcScope
            _ | Lens.nullOf (val . V._BLam) src ->
                -- Apply if compatible with a function
                do
                    argType <- liftInfer srcScope newUnbound
                    resType <- liftInfer srcScope newUnbound
                    _ <-
                        FuncType argType resType & T.TFun & newTerm
                        >>= unify s1
                        & liftInfer srcScope
                    arg <-
                        forTypeWithoutSplit argType & liftInfer srcScope
                        <&> annotations %~ (\t -> (def, IResult t srcScope))
                    let applied = V.Apply src arg & V.BApp & mkResult resType
                    pure applied
                        <|>
                        do
                            -- If the suggested argument has holes in it
                            -- then stop suggesting there to avoid "overwhelming"..
                            Lens.nullOf (ExprLens.valLeafs . V._LHole) arg & guard
                            termTransformsWithoutSplit def applied
            _ -> empty
    where
        mkResult t = Ann (def, IResult t srcScope)
        srcScope = src ^. ann . _2 . irScope

termOptionalTransformsWithoutSplit ::
    a -> AnnotatedTerm a -> StateT InferState [] (AnnotatedTerm a)
termOptionalTransformsWithoutSplit def src =
    pure src <|>
    termTransformsWithoutSplit def src

-- | Suggest values that fit a type, may "split" once, to suggest many
-- injects for a sum type. These are offerred in holes (not fragments).
forType ::
    (Unify m T.Type, Unify m T.Row) => UType m -> m [TypedTerm m]
forType t =
    do
        -- TODO: DSL for matching/deref'ing UVar structure
        (_, typ) <- semiPruneLookup t
        case typ ^? _UTerm . uBody . T._TVariant of
            Nothing -> forTypeUTermWithoutSplit typ <&> Ann t <&> (:[])
            Just r -> forVariant r [V.BLeaf V.LHole] <&> Lens.mapped %~ Ann t

forVariant ::
    (Unify m T.Type, Unify m T.Row) =>
    URow m ->
    [Tree V.Term (Ann (UType m))] ->
    m [Tree V.Term (Ann (UType m))]
forVariant r def =
    semiPruneLookup r <&> (^? _2 . _UTerm . uBody . T._RExtend) >>=
    \case
    Nothing -> pure def
    Just extend -> forVariantExtend extend

forVariantExtend ::
    (Unify m T.Type, Unify m T.Row) =>
    Tree (RowExtend T.Tag T.Type T.Row) (UVarOf m) ->
    m [Tree V.Term (Ann (UType m))]
forVariantExtend (RowExtend tag typ rest) =
    (:)
    <$> (forTypeWithoutSplit typ <&> V.Inject tag <&> V.BInject)
    <*> forVariant rest []

forTypeWithoutSplit ::
    (Unify m T.Type, Unify m T.Row) =>
    UType m -> m (TypedTerm m)
forTypeWithoutSplit t = semiPruneLookup t <&> snd >>= forTypeUTermWithoutSplit <&> Ann t

forTypeUTermWithoutSplit ::
    (Unify m T.Type, Unify m T.Row) =>
    Tree (UTerm (UVarOf m)) T.Type -> m (Tree V.Term (Ann (UType m)))
forTypeUTermWithoutSplit t =
    case t ^? _UTerm . uBody of
    Just (T.TRecord row) -> suggestRecord row
    Just (T.TFun (FuncType param result)) ->
        semiPruneLookup param <&> (^? _2 . _UTerm . uBody . T._TVariant) >>=
        \case
        Just row -> suggestCaseWith row result
        Nothing -> forTypeWithoutSplit result <&> V.Lam "var" <&> V.BLam
    _ -> V.BLeaf V.LHole & pure

suggestRecord ::
    (Unify m T.Type, Unify m T.Row) => URow m -> m (Tree V.Term (Ann (UType m)))
suggestRecord r =
    semiPruneLookup r <&> (^? _2 . _UTerm . uBody) >>=
    \case
    Just T.REmpty -> V.BLeaf V.LRecEmpty & pure
    Just (T.RExtend (RowExtend tag typ rest)) ->
        RowExtend tag
        <$> autoLambdas typ
        <*> (Ann <$> newTerm (T.TRecord rest) <*> suggestRecord rest)
        <&> V.BRecExtend
    _ -> V.BLeaf V.LHole & pure

suggestCaseWith ::
    (Unify m T.Type, Unify m T.Row) =>
    URow m -> UType m -> m (Tree V.Term (Ann (UType m)))
suggestCaseWith variantType resultType =
    semiPruneLookup variantType <&> (^? _2 . _UTerm . uBody) >>=
    \case
    Just T.REmpty -> V.BLeaf V.LAbsurd & pure
    Just (T.RExtend (RowExtend tag fieldType rest)) ->
        RowExtend tag
        <$> (Ann
                <$> mkCaseType fieldType
                <*> (autoLambdas resultType <&> V.Lam "var" <&> V.BLam))
        <*> (Ann
                <$> (T.TVariant rest & newTerm >>= mkCaseType)
                <*> suggestCaseWith rest resultType)
        <&> V.BCase
        where
            mkCaseType which = FuncType which resultType & T.TFun & newTerm
    _ ->
        -- TODO: Maybe this should be a lambda, like a TFun from non-variant
        V.BLeaf V.LHole & pure

autoLambdas :: Unify m T.Type => UType m -> m (TypedTerm m)
autoLambdas typ =
    semiPruneLookup typ <&> (^? _2 . _UTerm . uBody . T._TFun . funcOut) >>=
    \case
    Just result -> autoLambdas result <&> V.Lam "var" <&> V.BLam
    Nothing -> V.BLeaf V.LHole & pure
    <&> Ann typ

fillHoles :: a -> AnnotatedTerm a -> PureInfer (AnnotatedTerm a)
fillHoles def (Ann pl (V.BLeaf V.LHole)) =
    forTypeWithoutSplit (pl ^. _2 . irType)
    <&> annotations %~ (\t -> (def, IResult t (pl ^. _2 . irScope)))
fillHoles def (Ann pl (V.BApp (V.Apply func arg))) =
    -- Dont fill in holes inside apply funcs. This may create redexes..
    fillHoles def arg <&> V.Apply func <&> V.BApp <&> Ann pl
fillHoles _ v@(Ann _ (V.BGetField (V.GetField (Ann _ (V.BLeaf V.LHole)) _))) =
    -- Dont fill in holes inside get-field.
    pure v
fillHoles def x = (val . monoChildren) (fillHoles def) x

-- | Transform by wrapping OR modifying a term. Used by both holes and
-- fragments to expand "seed" terms. Holes include these as results
-- whereas fragments emplace their content inside holes of these
-- results.
termTransformsWithModify ::
    a -> AnnotatedTerm a ->
    StateT InferState [] (AnnotatedTerm a)
termTransformsWithModify _ v@(Ann _ V.BLam {}) = pure v -- Avoid creating a surprise redex
termTransformsWithModify _ v@(Ann pl0 (V.BInject (V.Inject tag (Ann pl1 (V.BLeaf V.LHole))))) =
    -- Variant:<hole> ==> Variant.
    pure (Ann pl0 (V.BInject (V.Inject tag (Ann pl1 (V.BLeaf V.LRecEmpty)))))
    <|> pure v
termTransformsWithModify def src =
    src ^. ann . _2 . irType & semiPruneLookup & liftInfer srcScope
    <&> (^? _2 . _UTerm . uBody)
    >>=
    \case
    Just T.TRecord{} | Lens.has ExprLens.valVar src ->
        -- A "params record" (or just a let item which is a record..)
        pure src
    _ ->
        do
            t <- fillHoles def src & liftInfer srcScope
            pure t <|> termTransforms def t
    where
        srcScope = src ^. ann . _2 . irScope