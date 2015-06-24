{-# LANGUAGE OverloadedStrings #-}
-- | Manage, read, write lambda-associated param lists
module Lamdu.Sugar.Convert.ParamList
    ( ParamList
    , mkProp
    , loadForLambdas
    ) where

import           Control.Applicative (Applicative(..), (<$>))
import qualified Control.Lens as Lens
import           Control.Lens.Operators
import           Control.Monad.Trans.Class (MonadTrans(..))
import           Control.Monad.Trans.Either.Utils (eitherToMaybeT)
import           Control.Monad.Trans.Maybe (MaybeT)
import           Control.Monad.Trans.State (StateT(..), mapStateT)
import qualified Control.Monad.Trans.State as State
import           Control.MonadA (MonadA)
import qualified Data.Store.Property as Property
import           Data.Store.Transaction (Transaction)
import qualified Data.Store.Transaction as Transaction
import           Data.Traversable (traverse)
import qualified Lamdu.Expr.IRef as ExprIRef
import qualified Lamdu.Expr.Lens as ExprLens
import           Lamdu.Expr.Type (Type)
import qualified Lamdu.Expr.Type as T
import qualified Lamdu.Expr.UniqueId as UniqueId
import           Lamdu.Expr.Val (Val(..))
import qualified Lamdu.Expr.Val as V
import           Lamdu.Infer (Infer)
import qualified Lamdu.Infer as Infer
import           Lamdu.Infer.Unify (unify)
import           Lamdu.Infer.Update (update)
import qualified Lamdu.Infer.Update as Update
import qualified Lamdu.Sugar.Convert.Input as Input

type T = Transaction
type ParamList = [T.Tag]

mkProp ::
    MonadA m =>
    ExprIRef.ValI m -> Transaction.MkProperty m (Maybe ParamList)
mkProp lambdaI =
    Transaction.assocDataRef "field param list" $
    UniqueId.toGuid lambdaI

loadStored :: MonadA m => ExprIRef.ValIProperty m -> T m (Maybe ParamList)
loadStored = Transaction.getP . mkProp . Property.value

mkFuncType :: ParamList -> Infer Type
mkFuncType paramList =
    T.TFun
    <$> (T.TRecord <$> foldr step (pure T.CEmpty) paramList)
    <*> Infer.freshInferredVar "lamres"
    where
        step tag rest = T.CExtend tag <$> Infer.freshInferredVar "tagpar" <*> rest

loadForLambdas ::
    MonadA m =>
    (Val (Input.Payload m a), Infer.Context) ->
    MaybeT (T m) (Val (Input.Payload m a), Infer.Context)
loadForLambdas (val, ctx) =
    do
        Lens.itraverseOf_ ExprLens.subExprPayloads loadLambdaParamList val
        val & traverse . Input.inferred %%~ update & Update.run & State.gets
    & (`runStateT` ctx)
    where
        loadLambdaParamList (V.Val _ V.BAbs {}) pl = loadUnifyParamList pl
        loadLambdaParamList _ _ = return ()

        loadUnifyParamList pl =
            case pl ^. Input.mStored of
            Nothing -> return ()
            Just stored ->
                do
                    mParamList <- loadStored stored & lift & lift
                    case mParamList of
                        Nothing -> return ()
                        Just paramList ->
                            do
                                funcType <- mkFuncType paramList
                                unify typ funcType
                            & Infer.run
                            & mapStateT eitherToMaybeT
            where
                typ = pl ^. Input.inferred . Infer.plType
