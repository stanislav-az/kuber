{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-incomplete-patterns #-}
{-# LANGUAGE FlexibleContexts #-}
module Cardano.Contrib.Kuber.Util
where

import Cardano.Api
import Data.ByteString (ByteString,readFile)
import qualified Cardano.Api.Shelley as Shelley
import qualified Data.Set as Set
import Control.Exception (try, throw)
import System.Environment (getEnv)
import System.Directory (doesFileExist)
import Cardano.Contrib.Kuber.Error
import Plutus.V1.Ledger.Api (fromBuiltin, toBuiltin, ToData, toData, CurrencySymbol (CurrencySymbol), TokenName (TokenName), PubKeyHash (PubKeyHash), Address)
import System.FilePath (joinPath)
import Cardano.Api.Shelley (ProtocolParameters (protocolParamUTxOCostPerWord), fromPlutusData, TxBody (ShelleyTxBody), Lovelace (Lovelace), toShelleyTxOut, Address (ShelleyAddress), fromShelleyStakeCredential, fromShelleyStakeReference, fromShelleyAddr, toShelleyAddr, fromShelleyPaymentCredential)
import qualified Cardano.Ledger.Alonzo.Tx as LedgerBody
import Ouroboros.Network.Protocol.LocalTxSubmission.Client (SubmitResult(SubmitSuccess, SubmitFail))
import Data.Text.Conversions (convertText, Base16 (unBase16, Base16), FromText (fromText), ToText (toText))
import Data.Functor ((<&>))

import qualified Data.Text as T
import qualified Data.Aeson as Aeson
import Data.Text.Encoding
import Data.ByteString.Lazy (fromStrict, toStrict)
import qualified Data.Text.IO as TextIO
import qualified Cardano.Ledger.Alonzo.Rules.Utxo as Alonzo
import Plutus.V1.Ledger.Value (AssetClass(AssetClass))
import Data.String (fromString)
import PlutusTx.Builtins.Class (stringToBuiltinByteString)
-- import Shelley.Spec.Ledger.API (Credential(ScriptHashObj, KeyHashObj), KeyHash (KeyHash), StakeReference (StakeRefNull))
import Codec.Serialise (serialise)
import Cardano.Api.Byron (Address(ByronAddress))
import qualified Data.Aeson as JSON
import qualified Data.Text.Encoding as TSE
import Cardano.Contrib.Kuber.Parsers
import qualified Data.Map as Map
import Data.Char (toLower)
import Data.Set (Set)
import Cardano.Ledger.Shelley.API (Credential(ScriptHashObj, KeyHashObj), KeyHash (KeyHash), StakeReference (StakeRefNull))
import Data.Map (Map)
import qualified Codec.CBOR.Write as Cborg
import qualified Codec.CBOR.Encoding as Cborg
import qualified Cardano.Binary as Cborg
import qualified Data.ByteString as BS

localNodeConnInfo :: NetworkId -> FilePath   -> LocalNodeConnectInfo CardanoMode
localNodeConnInfo = LocalNodeConnectInfo (CardanoModeParams (EpochSlots 21600))

readSignKey :: FilePath -> IO (SigningKey PaymentKey)
readSignKey file = do
  eitherSkey<-try  readSkeyFromFile
  case eitherSkey of
    Left (e::IOError )-> fail  "There was error reading skey file"
    Right sk -> pure sk
  where
    readSkeyFromFile=do
      exists<-doesFileExist file
      if exists then pure () else  fail $ file ++ "  doesn't exist"
      content <-readBs file
      parseSignKey content

    readBs:: FilePath -> IO T.Text
    readBs  = TextIO.readFile


getDefaultSignKey :: IO (SigningKey PaymentKey)
getDefaultSignKey= getWorkPath ["default.skey"] >>= readSignKey

skeyToAddr:: SigningKey PaymentKey -> NetworkId -> Shelley.Address ShelleyAddr
skeyToAddr skey network =
  makeShelleyAddress  network  credential NoStakeAddress
  where
    credential=PaymentCredentialByKey  $ verificationKeyHash   $ getVerificationKey  skey

skeyToAddrInEra ::  SigningKey PaymentKey -> NetworkId -> AddressInEra AlonzoEra
skeyToAddrInEra skey network=makeShelleyAddressInEra network   credential NoStakeAddress
  where
    credential=PaymentCredentialByKey  $ verificationKeyHash   $ getVerificationKey  skey

addressInEraToAddressAny :: AddressInEra era -> AddressAny
addressInEraToAddressAny addr = case addr of { AddressInEra atie ad -> toAddressAny ad }


sKeyToPkh:: SigningKey PaymentKey -> PubKeyHash
sKeyToPkh skey= PubKeyHash (toBuiltin  $  serialiseToRawBytes  vkh)
  where
    vkh=verificationKeyHash   $ getVerificationKey  skey

addressInEraToPaymentKeyHash :: AddressInEra AlonzoEra -> Maybe (Hash PaymentKey)
addressInEraToPaymentKeyHash a = case a of { AddressInEra atie ad -> case ad of
                                               ByronAddress ad' -> Nothing
                                               ShelleyAddress net cre sr -> case fromShelleyPaymentCredential cre of
                                                 PaymentCredentialByKey ha -> Just ha
                                                 PaymentCredentialByScript sh -> Nothing
                                    }

pkhToMaybeAddr:: NetworkId -> PubKeyHash -> Maybe (AddressInEra  AlonzoEra)
pkhToMaybeAddr network (PubKeyHash pkh) =do
    key <- vKey
    Just $ makeShelleyAddressInEra  network (PaymentCredentialByKey key)  NoStakeAddress
  where
    paymentCredential _vkey=PaymentCredentialByKey _vkey
    vKey= deserialiseFromRawBytes (AsHash AsPaymentKey) $fromBuiltin pkh

addrToMaybePkh :: Cardano.Api.Shelley.Address ShelleyAddr -> Maybe PubKeyHash
addrToMaybePkh (ShelleyAddress net cre sr) = do
  PubKeyHash . toBuiltin <$> hash
  where
    hash= case cre of
      ScriptHashObj _ ->Nothing
      KeyHashObj kh -> pure ( Cborg.serialize' kh)

    unHex ::  ToText a => a -> Maybe  ByteString
    unHex v = convertText (toText v) <&> unBase16

addrInEraToPkh :: MonadFail m =>AddressInEra AlonzoEra -> m PubKeyHash
addrInEraToPkh a = case a of { AddressInEra atie ad -> case ad of
                                      ByronAddress ad' -> fail "Byron address is not supported"
                                      a@(ShelleyAddress net cre sr) -> case addrToMaybePkh a of
                                        Nothing -> fail "Expected PublicKey address got Script Address"
                                        Just pkh -> pure pkh }
    where
    unHex ::  ToText a => a -> Maybe  ByteString
    unHex v = convertText (toText v) <&> unBase16

unstakeAddr :: AddressInEra AlonzoEra -> AddressInEra AlonzoEra
unstakeAddr a = case a of { AddressInEra atie ad -> case ad of
                                      ByronAddress ad' ->a
                                      ShelleyAddress net cre sr ->  shelleyAddressInEra $ ShelleyAddress net cre StakeRefNull }

performQuery :: LocalNodeConnectInfo CardanoMode -> QueryInShelleyBasedEra AlonzoEra b -> IO (Either FrameworkError b)
performQuery conn q=
  do
  a <-queryNodeLocalState conn Nothing  qFilter
  case a of
    Left af -> pure $ Left $ FrameworkError NodeQueryError (show af)
    Right e -> case e of
      Left em -> pure  $ Left $ FrameworkError EraMisMatch  (show em)
      Right uto -> pure $ Right  uto

  where
  qFilter = QueryInEra AlonzoEraInCardanoMode
                    $ QueryInShelleyBasedEra ShelleyBasedEraAlonzo q


queryUtxos :: LocalNodeConnectInfo CardanoMode-> Set AddressAny -> IO (Either FrameworkError  (UTxO AlonzoEra))
queryUtxos conn addr= performQuery conn (QueryUTxO (QueryUTxOByAddress  addr))

resolveTxins :: LocalNodeConnectInfo CardanoMode -> Set TxIn -> IO (Either FrameworkError (UTxO AlonzoEra))
resolveTxins conn ins= performQuery conn (QueryUTxO ( QueryUTxOByTxIn ins))


getDefaultConnection :: String -> NetworkId ->  IO (LocalNodeConnectInfo CardanoMode)
getDefaultConnection networkName networkId= do
  sockEnv <- try $ getEnv "CARDANO_NODE_SOCKET_PATH"
  socketPath <-case  sockEnv of
    Left (e::IOError) -> do
          defaultSockPath<- getWorkPath ( if null networkName then ["node.socket"] else [networkName,"node.socket"])
          exists<-doesFileExist defaultSockPath
          if exists then return defaultSockPath else  (error $ "Socket File is Missing: "++defaultSockPath ++"\n\tSet environment variable CARDANO_NODE_SOCKET_PATH  to use different path")
    Right s -> pure s
  pure (localNodeConnInfo networkId socketPath )

getNetworkFromEnv :: String -> IO NetworkId
getNetworkFromEnv envKey =  do
  networkEnv <- try $ getEnv envKey
  case  networkEnv of
    Left (e::IOError) -> do
          pure (Testnet  (NetworkMagic 1097911063))
    Right s ->  case map toLower s of
      "mainnet" -> pure  Mainnet
      "testnet" -> pure $ Testnet  (NetworkMagic 1097911063)
      _  -> case read s of
        Just v -> pure (Testnet  (NetworkMagic v))
        _ -> fail "Invalid network id"

queryProtocolParam :: LocalNodeConnectInfo CardanoMode -> IO ProtocolParameters
queryProtocolParam conn=do
  paramQueryResult<-queryNodeLocalState conn Nothing $
            QueryInEra AlonzoEraInCardanoMode
                  $ QueryInShelleyBasedEra ShelleyBasedEraAlonzo QueryProtocolParameters
  case paramQueryResult of
    Left af -> error  "QueryProtocolParam: Acquire Failure"
    Right e -> case e of
      Left em -> error "QueryrotocolParam: Missmatched Era"
      Right pp -> return pp

querySystemStart conn=do
  result<-queryNodeLocalState conn Nothing QuerySystemStart
  case result of
    Left af -> error "Acquire Failure"
    Right ss -> pure ss

queryEraHistory :: LocalNodeConnectInfo CardanoMode -> IO (EraHistory CardanoMode)
queryEraHistory conn=do
  result <- queryNodeLocalState conn Nothing (QueryEraHistory CardanoModeIsMultiEra)
  case result of
    Left af -> error "Acquire Failure"
    Right eh -> pure eh

getWorkPath :: [FilePath] -> IO  FilePath
getWorkPath paths= do
  f <- getWorkPathFunc
  pure $ f paths

getWorkPathFunc :: IO( [FilePath] -> FilePath )
getWorkPathFunc = do
  eitherHome <-try $ getEnv "HOME"
  eitherCardanoHome <- try $ getEnv "CARDANO_HOME"
  case eitherCardanoHome of
    Left (e::IOError) ->   case eitherHome of
        Left (e::IOError) -> error "Can't get Home directory. Missing   HOME and CARDANO_HOME"
        Right home -> pure $ f [home,".cardano"]
    Right home ->  pure $ f  [home]
    where
      f a b = joinPath $ a ++ b

dataToScriptData :: (ToData a1) => a1 -> ScriptData
dataToScriptData sData =  fromPlutusData $ toData sData

signAndSubmitTxBody :: LocalNodeConnectInfo CardanoMode
  -> TxBody AlonzoEra -> [SigningKey PaymentKey] -> IO (Tx AlonzoEra)
signAndSubmitTxBody conn txBody skeys= do
      let (ins,outs)=case txBody of { ShelleyTxBody sbe (LedgerBody.TxBody ins outs _ _ _ _ _ _ _ _ _ _ _ ) scs tbsd m_ad tsv -> (ins,outs) }
          tx = makeSignedTransaction (map toWitness skeys) txBody -- witness and txBody
      executeSubmitTx conn tx
      pure tx
  where
    toWitness skey = makeShelleyKeyWitness txBody (WitnessPaymentKey skey)

executeSubmitTx :: LocalNodeConnectInfo CardanoMode -> Tx AlonzoEra -> IO ()
executeSubmitTx conn  tx= do
      res <-submitTxToNodeLocal conn $  TxInMode tx AlonzoEraInCardanoMode
      case res of
        SubmitSuccess ->  pure ()
        SubmitFail reason ->
          case reason of
            TxValidationErrorInMode err _eraInMode ->  error $ "SubmitTx: " ++ show  err
            TxValidationEraMismatch mismatchErr -> error $ "SubmitTx: " ++ show  mismatchErr

queryTxins :: LocalNodeConnectInfo CardanoMode-> [TxIn] -> IO (UTxO AlonzoEra)
queryTxins conn txin=do
  a <-queryNodeLocalState conn Nothing $ utxoQuery txin
  case a of
    Left af -> error $ show af
    Right e -> case e of
      Left em -> error $ show em
      Right uto -> return uto

  where
  utxoQuery qfilter= QueryInEra AlonzoEraInCardanoMode
                    $ QueryInShelleyBasedEra ShelleyBasedEraAlonzo (QueryUTxO (QueryUTxOByTxIn  (Set.fromList qfilter)) )


nullValue :: Value -> Bool
nullValue v = not $ any (\(aid,Quantity q) -> q>0) (valueToList v)

positiveValue :: Value -> Bool
positiveValue v = not $ any (\(aid,Quantity q) -> q<0) (valueToList v)

calculateTxoutMinLovelace :: TxOut CtxUTxO  AlonzoEra -> ProtocolParameters -> Maybe Lovelace
calculateTxoutMinLovelace txout pParams=do
  Lovelace costPerWord <- protocolParamUTxOCostPerWord pParams
  Just $ Lovelace  $ Alonzo.utxoEntrySize (toShelleyTxOut ShelleyBasedEraAlonzo  txout) * costPerWord

calculateTxoutMinLovelaceFunc :: ProtocolParameters  -> Maybe ( TxOut CtxTx   AlonzoEra -> Lovelace)
calculateTxoutMinLovelaceFunc pParams = do
  Lovelace costPerWord <- protocolParamUTxOCostPerWord pParams
  pure $ f costPerWord
  where
    f cpw txout =Lovelace  $ Alonzo.utxoEntrySize (toShelleyTxOut ShelleyBasedEraAlonzo  $  toCtxUTxOTxOut txout) * cpw

calculateTxoutMinLovelaceWithcpw :: Lovelace -> TxOut CtxTx AlonzoEra -> Lovelace  
calculateTxoutMinLovelaceWithcpw (Lovelace cpw) txout = Lovelace  $ Alonzo.utxoEntrySize (toShelleyTxOut ShelleyBasedEraAlonzo  $  toCtxUTxOTxOut txout) * cpw


toPlutusAssetClass :: AssetId -> AssetClass
toPlutusAssetClass (AssetId (PolicyId hash) (AssetName name)) = AssetClass (CurrencySymbol $ toBuiltin $ serialiseToRawBytes hash , TokenName $ toBuiltin name)
toPlutusAssetClass AdaAssetId  =AssetClass (CurrencySymbol $ fromString "", TokenName $ fromString "")


txoutListSum :: [TxOut ctx era ] -> Value
txoutListSum = foldMap toValue
  where
    toValue (TxOut _ val _)= case val of
      TxOutValue masie va -> va

utxoListSum :: [(a, TxOut ctx era)] -> Value
utxoListSum l = txoutListSum (map snd l)

utxoMapSum :: Map a (TxOut ctx era) -> Value
utxoMapSum x = txoutListSum  $ Map.elems x

utxoSum :: UTxO AlonzoEra  -> Value
utxoSum (UTxO uMap)= utxoMapSum uMap


createTxInScriptWitness :: ScriptInAnyLang -> ScriptData -> ScriptData -> ExecutionUnits -> Either FrameworkError  (ScriptWitness WitCtxTxIn AlonzoEra)
createTxInScriptWitness anyScript datum redeemer exUnits = do
  ScriptInEra langInEra script' <- validateScriptSupportedInEra' AlonzoEra anyScript
  case script' of
    PlutusScript version pscript ->
      pure $ PlutusScriptWitness langInEra version pscript (ScriptDatumForTxIn  datum) redeemer exUnits
    SimpleScript version sscript ->Left $ FrameworkError  WrongScriptType "Simple Script used in Txin"

createPlutusMintingWitness :: ScriptInAnyLang ->ScriptData ->ExecutionUnits -> Either FrameworkError  (ScriptWitness WitCtxMint AlonzoEra)
createPlutusMintingWitness anyScript redeemer exUnits = do
  ScriptInEra langInEra script' <- validateScriptSupportedInEra' AlonzoEra anyScript
  case script' of
    PlutusScript version pscript ->
      pure $ PlutusScriptWitness langInEra version pscript NoScriptDatumForMint redeemer exUnits
    SimpleScript version sscript -> Left $ FrameworkError WrongScriptType "Simple script not supported on creating plutus script witness."

createSimpleMintingWitness :: ScriptInAnyLang -> Either FrameworkError (ScriptWitness WitCtxMint AlonzoEra)
createSimpleMintingWitness anyScript = do
  ScriptInEra langInEra script' <- validateScriptSupportedInEra' AlonzoEra anyScript
  case script' of
    PlutusScript version pscript -> Left $ FrameworkError  WrongScriptType "Plutus script not supported on creating simple script witness"
    SimpleScript version sscript -> pure $ SimpleScriptWitness langInEra version sscript


validateScriptSupportedInEra' ::  CardanoEra era -> ScriptInAnyLang -> Either FrameworkError (ScriptInEra era)
validateScriptSupportedInEra' era script@(ScriptInAnyLang lang _) =
  case toScriptInEra era script of
    Nothing -> Left $ FrameworkError WrongScriptType   (show lang ++ " not supported in " ++ show era ++ " era")
    Just script' -> pure script'


toHexString :: (FromText a1, ToText (Base16 a2)) => a2 -> a1
toHexString bs = fromText $  toText (Base16 bs )