{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Benchmark of 'validateEbClosure', the Leios voting thread's validation of
-- an EB's closure, against the real Cardano ledger in the Dijkstra era.
--
-- The closures are of designed shape, the two kinds the voters meet:
--
--   * __old-input__: every tx spends outputs that were in the UTxO set before
--     the closure, so the closure's resolved input table holds one entry per
--     input;
--   * __chained__: tx @n@ spends tx @n-1@'s outputs, so the table holds only
--     the first tx's inputs.
--
-- Every closure is validated twice against the same tx-cache: the first pass
-- applies every tx in full (the cache holds them unapplied, as a fetch leaves
-- them), the second reapplies every tx (the first pass tagged them). The
-- figures are the whole call's wall-clock time over the tx count, the best of
-- the repetitions.
--
-- @cabal run leios-voting-bench -- [--reps N] [SIZE ...]@, default sizes
-- 1000 3000 6000, three repetitions.
module Main (main) where

import qualified Cardano.Chain.Update as CC.Update
import Cardano.Crypto.DSIGN (genKeyDSIGN)
import Cardano.Crypto.Seed (mkSeedFromBytes)
import Cardano.Ledger.Alonzo.Scripts
  ( AsIx (..)
  , ExUnits (..)
  , fromPlutusScript
  , mkPlutusScript
  , mkSpendingPurpose
  )
import Cardano.Ledger.Alonzo.Tx
  ( IsPhase2Valid (..)
  , hashScriptIntegrity
  , isValidTxL
  , mkScriptIntegrity
  )
import Cardano.Ledger.Alonzo.TxBody (collateralInputsTxBodyL, scriptIntegrityHashTxBodyL)
import Cardano.Ledger.Alonzo.TxWits (Redeemers (..), rdmrsTxWitsL)
import Cardano.Ledger.Api
  ( Addr (..)
  , DijkstraEra
  , PParams
  , Script
  , Tx
  , TxOut
  , addrTxWitsL
  , bodyTxL
  , eraProtVerLow
  , hashScript
  , inputsTxBodyL
  , mkBasicTx
  , mkBasicTxBody
  , mkBasicTxOut
  , outputsTxBodyL
  , ppMaxTxSizeL
  , scriptTxWitsL
  , txIdTx
  , witsTxL
  )
import Cardano.Ledger.Api.Tx.In (TxIn (..))
import Cardano.Ledger.BaseTypes
  ( Nonce (..)
  , ProtVer (..)
  , TxIx (..)
  , getVersion
  , knownNonZeroBounded
  )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (TopTx)
import Cardano.Ledger.Credential (Credential (..), StakeReference (..))
import Cardano.Ledger.Hashes (hashAnnotated)
import Cardano.Ledger.Plutus.Data (Data (..))
import Cardano.Ledger.Plutus.Language (Language (..), Plutus (..), PlutusBinary (..))
import Cardano.Ledger.Shelley.Genesis (ShelleyGenesis (..))
import Cardano.Ledger.Shelley.LedgerState (curPParamsEpochStateL, nesEsL)
import Cardano.Ledger.Val (inject)
import Cardano.Protocol.Crypto (StandardCrypto)
import Cardano.Protocol.TPraos.OCert (KESPeriod (..))
import Control.DeepSeq (force)
import Control.Monad (foldM, forM_, void, when)
import qualified Data.ByteString as BS
import Data.Function ((&))
import qualified Data.Map.Strict as Map
import Data.Proxy (Proxy (..))
import Data.SOP.Index (Index (..))
import qualified Data.Sequence.Strict as StrictSeq
import qualified Data.Set as Set
import qualified Data.Vector.Strict as V
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import LeiosDemoTypes
  ( LeiosEb (..)
  , LeiosPoint (..)
  , LeiosTx (..)
  , ProtVerParity
  , RbHash (..)
  , SerializedEbBody
  , encodeLeiosEbSize
  , hashLeiosEb
  , hashLeiosTx
  , serializeEbBody
  , serializeTxForLeios
  )
import LeiosTxCache
  ( LeiosTxCache (..)
  , defaultLeiosTxCacheShift
  , newPureLeiosTxCache
  )
import LeiosVoting (EbClosureVerdict (..), validateEbClosure)
import Lens.Micro ((.~), (^.))
import Ouroboros.Consensus.Block (SlotNo (..))
import Ouroboros.Consensus.BlockchainTime (slotLengthFromSec)
import Ouroboros.Consensus.Cardano.Block (CardanoBlock, CardanoEras, pattern LedgerStateDijkstra)
import Ouroboros.Consensus.Config (configLedger)
import Ouroboros.Consensus.Config.SecurityParam (SecurityParam (..))
import Ouroboros.Consensus.HardFork.Combinator.Ledger (injectLedgerTables)
import Ouroboros.Consensus.Ledger.Abstract (LedgerConfig, LedgerState)
import Ouroboros.Consensus.Ledger.Extended (ExtLedgerState (..))
import Ouroboros.Consensus.Ledger.Tables (LedgerTables (..), ValuesMK (..))
import Ouroboros.Consensus.Ledger.Tables.Combinators (ltliftA2)
import Ouroboros.Consensus.Ledger.Tables.MapKind (EmptyMK)
import Ouroboros.Consensus.Ledger.Tables.Utils (forgetLedgerTables, restrictValuesMK)
import Ouroboros.Consensus.Node.ProtocolInfo (NumCoreNodes (..), ProtocolInfo (..))
import Ouroboros.Consensus.NodeId (CoreNodeId (..))
import Ouroboros.Consensus.Protocol.PBFT (PBftSignatureThreshold (..))
import Ouroboros.Consensus.Protocol.Praos2 (Praos2)
import Ouroboros.Consensus.Shelley.Ledger.Block (ShelleyBlock)
import Ouroboros.Consensus.Shelley.Ledger.Ledger (BigEndianTxIn (..), shelleyLedgerState)
import Ouroboros.Consensus.Shelley.Ledger.SupportsProtocol ()
import Ouroboros.Consensus.Storage.LeiosDB
  ( LeiosDbReader
  , LeiosDbWriter (..)
  , Promise (..)
  , newLeiosDBInMemory
  , withReader
  , withWriter
  )
import qualified PlutusCore as PLC
import qualified PlutusCore.MkPlc as PLC
import qualified PlutusCore.Version as PLC
import qualified PlutusLedgerApi.V1 as PV1
import qualified PlutusLedgerApi.V3 as PV3
import System.Environment (getArgs)
import System.FS.API (SomeHasFS (..))
import qualified System.FS.Sim.MockFS as MockFS
import qualified System.FS.Sim.STM as Sim
import System.IO (BufferMode (..), hSetBuffering, stdout)
import System.Mem (performMajorGC)
import Test.Cardano.Ledger.Core.KeyPair (mkWitnessVKey)
import Test.Cardano.Ledger.Plutus (testingEvaluationContext)
import Test.Consensus.Cardano.ProtocolInfo (Era (Dijkstra), hardForkInto, mkTestProtocolInfo)
import Test.QuickCheck.Gen (unGen)
import Test.QuickCheck.Random (mkQCGen)
import qualified Test.ThreadNet.Infra.Byron as Byron
import Test.ThreadNet.Infra.Shelley
  ( CoreNode (..)
  , DecentralizationParam (..)
  , genCoreNode
  , mkCredential
  , mkGenesisConfig
  , mkKesConfig
  , mkKeyPair
  , networkId
  , signTx
  )
import Test.Util.Slots (NumSlots (..))
import Text.Printf (printf)
import qualified UntypedPlutusCore as UPLC

type Blk = CardanoBlock StandardCrypto

type DijkstraBlock = ShelleyBlock (Praos2 StandardCrypto) DijkstraEra

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  (reps, sizes, plutus, heavy, heavyTxs, keyCounts) <- parseArgs <$> getArgs
  let coreNode = unGen (genCoreNode (KESPeriod 0)) (mkQCGen 0) 30
  pinfo <- mkProtocolInfo coreNode
  let lcfg = configLedger (pInfoConfig pinfo)
      base = forgetLedgerTables (ledgerState (pInfoInitLedger pinfo))
      pp = case ledgerState (pInfoInitLedger pinfo) of
        LedgerStateDijkstra st -> shelleyLedgerState st ^. nesEsL . curPParamsEpochStateL
        _ -> error "the initial ledger state is not in Dijkstra"
      measure kind nIn n = do
        let (txs, funded) = buildClosure coreNode pp kind nIn n
        results <- mapM (\_ -> runOnce lcfg base funded txs) [1 .. reps]
        let (applyNs, reapplyNs) = (minimum (map fst results), minimum (map snd results))
            ms ns = fromIntegral ns / 1e6 :: Double
            perTx ns = fromIntegral ns / 1e3 / fromIntegral n :: Double
            txBytes = sum (map (BS.length . serializeTxForLeios) txs) `div` n
        pure (Map.size funded, txBytes, ms applyNs, perTx applyNs, ms reapplyNs, perTx reapplyNs)
  putStrLn
    "| closure | inputs per tx | txs | tx bytes | table entries | apply: ms | per applied tx, us | reapply: ms | per reapplied tx, us |"
  putStrLn "|---|---|---|---|---|---|---|---|---|"
  forM_ sizes $ \n -> forM_ [OldInput, Chained] $ \kind -> forM_ [1, 2] $ \nIn -> do
    (entries, bytes, a, aTx, r, rTx) <- measure kind nIn n
    printf
      "| %s | %d | %d | %d | %d | %.1f | %.1f | %.1f | %.1f |\n"
      (kindName kind)
      nIn
      n
      bytes
      entries
      a
      aTx
      r
      rTx
  -- Plutus closures: every tx spends one output locked by a V3 script that
  -- loops the given number of times, old-input shape, at the first size given.
  -- The steps are what the standard cost model charges the script (a counting
  -- evaluation here); the test genesis charges nothing, so the declared units
  -- are nominal and the wall clock is the evaluation's.
  when (not (null plutus)) $ do
    putStrLn ""
    putStrLn
      "| closure | loop iterations per tx | script steps per tx, G | txs | tx bytes | apply: ms | per applied tx, us | reapply: ms | per reapplied tx, us |"
    putStrLn "|---|---|---|---|---|---|---|---|---|"
    forM_ plutus $ \iters -> do
      let n = head sizes
          (cpu, _mem) = scriptBudget (loopScript iters)
      (_, bytes, a, aTx, r, rTx) <- measure (ScriptLoop iters) 1 n
      printf
        "| plutus loop | %d | %.3f | %d | %d | %.1f | %.1f | %.1f | %.1f |\n"
        iters
        (fromIntegral cpu / 1e9 :: Double)
        n
        bytes
        a
        aTx
        r
        rTx
  -- Heavy closures: every tx spends one output from each of k distinct keys
  -- plus one script output, pays k+1 outputs, and carries k+1 signatures (the
  -- collateral's owner signs too) -- the shape of the testnet's stress
  -- transactions, with the script budget as a parameter.
  when (not (null heavy)) $ do
    putStrLn ""
    putStrLn
      "| closure | keys (signatures = keys + 1) | script steps per tx, G | txs | tx bytes | table entries | apply: ms | per applied tx, us | reapply: ms | per reapplied tx, us |"
    putStrLn "|---|---|---|---|---|---|---|---|---|---|"
    forM_ heavy $ \(k, iters) -> do
      let (cpu, _mem) = scriptBudget (loopScript iters)
      (entries, bytes, a, aTx, r, rTx) <- measure (Heavy k iters) 1 heavyTxs
      printf
        "| heavy | %d | %.3f | %d | %d | %d | %.1f | %.1f | %.1f | %.1f |\n"
        k
        (fromIntegral cpu / 1e9 :: Double)
        heavyTxs
        bytes
        entries
        a
        aTx
        r
        rTx
  -- Multi-key transfers: every tx spends one output of each of k distinct
  -- keys and pays k outputs, so it carries k signatures and no script --
  -- old-input shape, at every size given.
  when (not (null keyCounts)) $ do
    putStrLn ""
    putStrLn
      "| closure | keys (signatures = keys) | txs | tx bytes | table entries | apply: ms | per applied tx, us | reapply: ms | per reapplied tx, us |"
    putStrLn "|---|---|---|---|---|---|---|---|---|"
    forM_ sizes $ \n -> forM_ keyCounts $ \k -> do
      (entries, bytes, a, aTx, r, rTx) <- measure (Keys k) 1 n
      printf
        "| keys | %d | %d | %d | %d | %.1f | %.1f | %.1f | %.1f |\n"
        k
        n
        bytes
        entries
        a
        aTx
        r
        rTx
 where
  parseArgs :: [String] -> (Int, [Int], [Integer], [(Int, Integer)], Int, [Int])
  parseArgs = go (3, [], [], [], 100, [])
   where
    go (_, acc, pl, hv, ht, ks) ("--reps" : r : rest) = go (read r, acc, pl, hv, ht, ks) rest
    go (reps, acc, _, hv, ht, ks) ("--plutus" : p : rest) = go (reps, acc, map read (commas p), hv, ht, ks) rest
    go (reps, acc, pl, _, ht, ks) ("--heavy" : h : rest) = go (reps, acc, pl, map pair (commas h), ht, ks) rest
    go (reps, acc, pl, hv, _, ks) ("--heavy-txs" : t : rest) = go (reps, acc, pl, hv, read t, ks) rest
    go (reps, acc, pl, hv, ht, _) ("--keys" : k : rest) = go (reps, acc, pl, hv, ht, map read (commas k)) rest
    go (reps, acc, pl, hv, ht, ks) (s : rest) = go (reps, acc ++ [read s], pl, hv, ht, ks) rest
    go (reps, [], pl, hv, ht, ks) [] = (reps, [1000, 3000, 6000], pl, hv, ht, ks)
    go (reps, acc, pl, hv, ht, ks) [] = (reps, acc, pl, hv, ht, ks)
    commas = words . map (\c -> if c == ',' then ' ' else c)
    pair s = case break (== ':') s of
      (k, ':' : i) -> (read k, read i)
      _ -> error ("--heavy expects KEYS:ITERATIONS, got " <> s)

-- * The closures

data Kind
  = OldInput
  | Chained
  | -- | Every tx spends an output locked by 'loopScript' with this many iterations.
    ScriptLoop Integer
  | -- | Every tx spends one output of each of this many keys and one output
    -- locked by 'loopScript' with this many iterations.
    Heavy Int Integer
  | -- | Every tx spends one output of each of this many keys and pays as
    -- many outputs: a transfer with this many signatures, no script.
    Keys Int

kindName :: Kind -> String
kindName = \case
  OldInput -> "old-input"
  Chained -> "chained"
  ScriptLoop _ -> "plutus loop"
  Heavy _ _ -> "heavy"
  Keys _ -> "keys"

-- | A Plutus V3 script that counts down from @n@ and returns unit, ignoring
-- its argument: @\\ctx -> (\\_ -> ()) (go n)@ with
-- @go = Z (\\go n -> if n == 0 then () else go (n - 1))@ via the Z
-- combinator, written in de Bruijn form. Its cost under the standard cost
-- model grows linearly with @n@ ('scriptBudget' reads it).
loopScript :: Integer -> PV3.SerialisedScript
loopScript n =
  PV3.serialiseUPLC . UPLC.Program () PLC.plcVersion110 $
    lam $ -- \ctx ->
      app (lam (PLC.mkConstant () ())) $ -- (\_ -> ()) applied to
        app (app z loopBody) (PLC.mkConstant @Integer () n)
 where
  var i = UPLC.Var () (UPLC.DeBruijn i)
  lam = UPLC.LamAbs () (UPLC.DeBruijn 0)
  app = UPLC.Apply ()
  builtin = UPLC.Builtin ()
  -- Z = \f -> (\x -> f (\v -> x x v)) (\x -> f (\v -> x x v))
  z = lam (app x x)
  x = lam (app (var 2) (lam (app (app (var 2) (var 2)) (var 1))))
  -- \go -> \n -> force (ifThenElse (equalsInteger n 0) (delay ()) (delay (go (subtractInteger n 1))))
  loopBody =
    lam . lam . UPLC.Force () $
      app
        ( app
            ( app
                (UPLC.Force () (builtin PLC.IfThenElse))
                (app (app (builtin PLC.EqualsInteger) (var 1)) (PLC.mkConstant @Integer () 0))
            )
            (UPLC.Delay () (PLC.mkConstant () ()))
        )
        ( UPLC.Delay
            ()
            (app (var 2) (app (app (builtin PLC.SubtractInteger) (var 1)) (PLC.mkConstant @Integer () 1)))
        )

-- | What the standard V3 cost model charges the script for one run: (steps,
-- memory). The genesis of the bench charges nothing, so this is read here.
scriptBudget :: PV3.SerialisedScript -> (Integer, Integer)
scriptBudget s = case PV3.deserialiseScript pv s of
  Left err -> error ("script: " <> show err)
  Right script -> case snd (PV3.evaluateScriptCounting pv PV3.Quiet ectx script (PV1.I 0)) of
    Left err -> error ("script evaluation: " <> show err)
    Right (PV3.ExBudget (PV3.ExCPU cpu) (PV3.ExMemory mem)) -> (PV3.fromSatInt cpu, PV3.fromSatInt mem)
 where
  pv = PV3.MajorProtocolVersion (getVersion (eraProtVerLow @DijkstraEra))
  ectx = testingEvaluationContext PlutusV3

-- | Every funded output carries this much, and every tx moves exactly what it
-- spends (fees are zero in the test genesis).
outputCoin :: Coin
outputCoin = Coin 1_000_000

-- | The closure's txs and the UTxO entries they spend, in the Dijkstra ledger's
-- own table type. An old-input closure of @n@ txs with @nIn@ inputs each needs
-- @n * nIn@ funded outputs; a chained one needs @nIn@; a Plutus one needs @n@
-- script-locked outputs and one plain output as everyone's collateral.
buildClosure ::
  CoreNode StandardCrypto ->
  PParams DijkstraEra ->
  Kind ->
  Int ->
  Int ->
  ([Tx TopTx DijkstraEra], Map.Map BigEndianTxIn (TxOut DijkstraEra))
buildClosure CoreNode{cnDelegateKey} pp kind nIn n = case kind of
  ScriptLoop iters -> plutusClosure iters
  Heavy k iters -> heavyClosure k iters
  Keys k -> keysClosure k
  _ -> (txs, funded)
 where
  addr = Addr networkId (mkCredential cnDelegateKey) StakeRefNull
  fundedOut = mkBasicTxOut addr (inject outputCoin)

  -- k distinct keys, the same ones for every tx of the closure
  keysOf k =
    [ genKeyDSIGN
        (mkSeedFromBytes (BS.replicate 30 0 <> BS.pack [fromIntegral (i `div` 256), fromIntegral i]))
    | i <- [1 .. k]
    ]
  keyOut sk = mkBasicTxOut (Addr networkId (mkCredential sk) StakeRefNull) (inject outputCoin)

  keysClosure k = (kTxs, kFunded)
   where
    keys = keysOf k
    -- tx j's inputs: one output of each key
    keyIn j i = fundedIn (j * k + i)
    kFunded =
      Map.fromList [(BigEndianTxIn (keyIn j i), keyOut sk) | j <- [0 .. n - 1], (i, sk) <- zip [0 ..] keys]
    kTxs = map keysTx [0 .. n - 1]
    keysTx :: Int -> Tx TopTx DijkstraEra
    keysTx j =
      force $
        tx0
          & witsTxL . addrTxWitsL
            .~ Set.fromList [mkWitnessVKey bodyHash (mkKeyPair sk) | sk <- keys]
     where
      tx0 =
        mkBasicTx
          ( mkBasicTxBody
              & inputsTxBodyL .~ Set.fromList [keyIn j i | i <- [0 .. k - 1]]
              & outputsTxBodyL .~ StrictSeq.fromList (map keyOut keys)
          )
      bodyHash = hashAnnotated (tx0 ^. bodyTxL)

  mkScript :: Integer -> Script DijkstraEra
  mkScript iters =
    maybe (error "loopScript: not a valid V3 script") fromPlutusScript $
      mkPlutusScript (Plutus (PlutusBinary (loopScript iters)) :: Plutus 'PlutusV3)

  scriptOutOf script =
    mkBasicTxOut (Addr networkId (ScriptHashObj (hashScript script)) StakeRefNull) (inject outputCoin)

  -- The redeemer index is the script input's position among the tx's inputs.
  redeemersFor :: Set.Set TxIn -> TxIn -> Redeemers DijkstraEra
  redeemersFor ins scriptIn =
    Redeemers
      ( Map.singleton
          (mkSpendingPurpose (AsIx (fromIntegral (Set.findIndex scriptIn ins))))
          (Data (PV1.I 0), ExUnits 0 0)
      )

  heavyClosure k iters = (hTxs, hFunded)
   where
    script = mkScript iters
    scriptOut = scriptOutOf script
    keys = keysOf k
    -- tx j's inputs: k key-locked outputs then the script's; one shared collateral
    keyIn j i = fundedIn (j * (k + 1) + i)
    scriptIn j = fundedIn (j * (k + 1) + k)
    collateralIn = fundedIn (n * (k + 1))
    hFunded =
      Map.fromList $
        (BigEndianTxIn collateralIn, fundedOut)
          : [(BigEndianTxIn (scriptIn j), scriptOut) | j <- [0 .. n - 1]]
          ++ [(BigEndianTxIn (keyIn j i), keyOut sk) | j <- [0 .. n - 1], (i, sk) <- zip [0 ..] keys]
    hTxs = map heavyTx [0 .. n - 1]
    heavyTx j =
      force $
        tx1
          & witsTxL . addrTxWitsL
            .~ Set.fromList [mkWitnessVKey bodyHash (mkKeyPair sk) | sk <- cnDelegateKey : keys]
     where
      ins = Set.fromList (scriptIn j : [keyIn j i | i <- [0 .. k - 1]])
      rdmrs = redeemersFor ins (scriptIn j)
      tx0 =
        mkBasicTx
          ( mkBasicTxBody
              & inputsTxBodyL .~ ins
              & collateralInputsTxBodyL .~ Set.singleton collateralIn
              & outputsTxBodyL .~ StrictSeq.fromList (fundedOut : map keyOut keys)
          )
          & witsTxL . scriptTxWitsL .~ Map.singleton (hashScript script) script
          & witsTxL . rdmrsTxWitsL .~ rdmrs
          & isValidTxL .~ Phase2Valid
      tx1 =
        tx0
          & bodyTxL . scriptIntegrityHashTxBodyL
            .~ (hashScriptIntegrity <$> mkScriptIntegrity pp tx0 (Set.singleton PlutusV3))
      bodyHash = hashAnnotated (tx1 ^. bodyTxL)

  plutusClosure iters = (scriptTxs, scriptFunded)
   where
    script = mkScript iters
    scriptHash = hashScript script
    scriptOut = scriptOutOf script
    collateralIn = fundedIn n
    scriptIns = [fundedIn i | i <- [0 .. n - 1]]
    scriptFunded =
      Map.fromList
        ((BigEndianTxIn collateralIn, fundedOut) : [(BigEndianTxIn i, scriptOut) | i <- scriptIns])
    scriptTxs = map scriptTx scriptIns

    -- One script input, the shared collateral, the value back to the key's
    -- address; the redeemer's declared units are nominal (see 'main').
    scriptTx :: TxIn -> Tx TopTx DijkstraEra
    scriptTx scriptIn =
      force . signTx cnDelegateKey $
        tx0
          & bodyTxL . scriptIntegrityHashTxBodyL
            .~ (hashScriptIntegrity <$> mkScriptIntegrity pp tx0 (Set.singleton PlutusV3))
     where
      rdmrs :: Redeemers DijkstraEra
      -- zero units: the genesis prices units, and its zero cost model charges
      -- the script nothing, so zero is both free and sufficient
      rdmrs = Redeemers (Map.singleton (mkSpendingPurpose (AsIx 0)) (Data (PV1.I 0), ExUnits 0 0))
      tx0 =
        mkBasicTx
          ( mkBasicTxBody
              & inputsTxBodyL .~ Set.singleton scriptIn
              & collateralInputsTxBodyL .~ Set.singleton collateralIn
              & outputsTxBodyL .~ StrictSeq.singleton fundedOut
          )
          & witsTxL . scriptTxWitsL .~ Map.singleton scriptHash script
          & witsTxL . rdmrsTxWitsL .~ rdmrs
          & isValidTxL .~ Phase2Valid

  -- The funded outputs: output 0 of never-applied dummy txs that differ only
  -- in the coin they name, so their ids differ.
  fundedIn :: Int -> TxIn
  fundedIn i = TxIn (txIdTx dummy) (TxIx 0)
   where
    dummy :: Tx TopTx DijkstraEra
    dummy =
      mkBasicTx $
        mkBasicTxBody
          & outputsTxBodyL .~ StrictSeq.singleton (mkBasicTxOut addr (inject (Coin (fromIntegral i))))

  mkTx :: [TxIn] -> Tx TopTx DijkstraEra
  mkTx ins =
    force . signTx cnDelegateKey . mkBasicTx $
      mkBasicTxBody
        & inputsTxBodyL .~ Set.fromList ins
        & outputsTxBodyL .~ StrictSeq.fromList (replicate nIn fundedOut)

  outsOf :: Tx TopTx DijkstraEra -> [TxIn]
  outsOf tx = [TxIn (txIdTx tx) (TxIx (fromIntegral k)) | k <- [0 .. nIn - 1]]

  fundedIns = case kind of
    Chained -> [fundedIn i | i <- [0 .. nIn - 1]]
    _ -> [fundedIn i | i <- [0 .. n * nIn - 1]]

  funded = Map.fromList [(BigEndianTxIn i, fundedOut) | i <- fundedIns]

  txs = case kind of
    Chained -> take n (chain (mkTx fundedIns))
    _ -> [mkTx (take nIn (drop (j * nIn) fundedIns)) | j <- [0 .. n - 1]]
   where
    chain tx = tx : chain (mkTx (outsOf tx))

-- * One run: a fresh LeiosDB and cache, the closure validated twice

-- | Nanoseconds of the apply pass and of the reapply pass.
runOnce ::
  LedgerConfig Blk ->
  LedgerState Blk EmptyMK ->
  Map.Map BigEndianTxIn (TxOut DijkstraEra) ->
  [Tx TopTx DijkstraEra] ->
  IO (Word64, Word64)
runOnce lcfg base funded txs = do
  db <- newLeiosDBInMemory
  withWriter db $ \writer -> do
    void $ await =<< writeEbPoint writer point (encodeLeiosEbSize eb)
    void $ await =<< writeEbBody writer point eb []
    void $ await =<< writeTxs writer point (zip [0 ..] bytes)
  withReader db $ \reader -> do
    cache <- newPureLeiosTxCache defaultLeiosTxCacheShift
    void $ insertAnnouncement cache slot rbHash (pointEbHash point)
    void $ insertBody cache (pointEbHash point) (serializeEbBody eb)
    -- acquired, as a fetch leaves them: unapplied
    void $ withLockedInsertUnappliedTx cache $ \w0 step ->
      foldM (\w (h, s) -> step w h s ()) w0 (zip hashes sizes)
    applyNs <- timed "apply" (validate reader cache)
    reapplyNs <- timed "reapply" (validate reader cache)
    pure (applyNs, reapplyNs)
 where
  slot = SlotNo 1
  rbHash = MkRbHash (BS.replicate 32 0)
  bytes = map serializeTxForLeios txs
  hashes = map (hashLeiosTx . MkLeiosTx) bytes
  sizes = map (fromIntegral . BS.length) bytes
  eb = MkLeiosEb (V.fromList (zip hashes sizes))
  point = MkLeiosPoint slot (hashLeiosEb eb)

  -- The closure's input table, as the node reads it from its ledger tables:
  -- the funded entries the closure's keys name.
  tables :: LedgerTables Blk ValuesMK
  tables =
    injectLedgerTables
      dijkstraIndex
      (LedgerTables (ValuesMK funded) :: LedgerTables DijkstraBlock ValuesMK)

  resolveValues keys = pure (ltliftA2 restrictValuesMK tables keys)

  validate :: LeiosDbReader IO -> LeiosTxCache IO () ProtVerParity SerializedEbBody -> IO ()
  validate reader cache =
    validateEbClosure lcfg reader cache resolveValues point base >>= \case
      EbClosureValid reapplied applied _ ->
        when (reapplied + applied /= length txs) $
          fail ("validated " <> show (reapplied, applied) <> " of " <> show (length txs))
      EbClosureInvalid err -> fail ("closure invalid: " <> show err)
      EbClosureUnreadable err -> fail ("closure unreadable: " <> show err)

  timed :: String -> IO () -> IO Word64
  timed _ act = do
    performMajorGC
    t0 <- getMonotonicTimeNSec
    act
    t1 <- getMonotonicTimeNSec
    pure (t1 - t0)

dijkstraIndex :: Index (CardanoEras StandardCrypto) DijkstraBlock
dijkstraIndex = IS (IS (IS (IS (IS (IS (IS IZ))))))

-- * The ledger: one core node, Dijkstra from epoch 0, as the ThreadNet Leios

-- tests build it

mkProtocolInfo :: CoreNode StandardCrypto -> IO (ProtocolInfo Blk)
mkProtocolInfo coreNode = do
  fs <- SomeHasFS <$> Sim.simHasFS' MockFS.empty
  fst
    <$> mkTestProtocolInfo @IO
      fs
      (CoreNodeId 0, coreNode)
      shelleyGenesis
      (CC.Update.ProtocolVersion 0 0 0)
      NeutralNonce
      genesisByron
      secretsByron
      (Just (PBftSignatureThreshold 1))
      dijkstraProtVer
      (hardForkInto Dijkstra)
 where
  k = SecurityParam (knownNonZeroBounded @10)
  slotLength = slotLengthFromSec 1
  dijkstraProtVer = ProtVer (eraProtVerLow @DijkstraEra) 0
  (genesisByron, secretsByron) =
    Byron.generateGenesisConfig slotLength (Byron.byronPBftParams k (NumCoreNodes 1))
  -- the ThreadNet genesis caps txs at 2,048 bytes; mainnet's cap lets the
  -- heavy closures through
  shelleyGenesis = sg{sgProtocolParams = sgProtocolParams sg & ppMaxTxSizeL .~ 16384}
   where
    sg =
      mkGenesisConfig
        dijkstraProtVer
        k
        (1 / 20)
        (DecentralizationParam 0)
        100_000_000_000_000
        slotLength
        (mkKesConfig (Proxy @StandardCrypto) (NumSlots 100))
        [coreNode]
