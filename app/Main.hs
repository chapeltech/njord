{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}

module Main (main) where

import Control.Exception (bracket, try)
import Control.Monad (forM_, unless, when)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson
  ( FromJSON (parseJSON)
  , ToJSON (toJSON)
  , object
  , withObject
  , (.:)
  , (.:?)
  , (.=)
  )
import Data.Aeson.Types ((.!=))
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Scientific (Scientific)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (Day)
import Database.PostgreSQL.Simple
  ( Connection
  , Only (Only)
  , SqlError (..)
  , close
  , connectPostgreSQL
  , execute
  , executeMany
  , query
  , query_
  , withTransaction
  )
import Database.PostgreSQL.Simple.FromRow (FromRow (fromRow), field)
import GHC.Generics (Generic)
import Network.HTTP.Types (hContentType, status200, status404)
import qualified Network.Wai as Wai
import Network.Wai.Handler.Warp (run)
import Servant
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

data App = App
  { appConnectionString :: BS.ByteString
  }

data Health = Health
  { healthStatus :: Text
  }
  deriving (Eq, Show, Generic)

instance ToJSON Health where
  toJSON Health{healthStatus} =
    object ["status" .= healthStatus]

data Book = Book
  { bookId :: Text
  , bookName :: Text
  , bookReportingAsset :: Text
  }
  deriving (Eq, Show, Generic)

instance FromRow Book where
  fromRow = Book <$> field <*> field <*> field

instance ToJSON Book where
  toJSON Book{bookId, bookName, bookReportingAsset} =
    object
      [ "id" .= bookId
      , "name" .= bookName
      , "reporting_asset" .= bookReportingAsset
      ]

data NewBook = NewBook
  { newBookId :: Text
  , newBookName :: Text
  , newBookReportingAsset :: Text
  , newBookCreateStandardAccounts :: Bool
  }
  deriving (Eq, Show, Generic)

instance FromJSON NewBook where
  parseJSON =
    withObject "NewBook" $ \o ->
      NewBook
        <$> o .: "id"
        <*> o .: "name"
        <*> o .: "reporting_asset"
        <*> o .:? "create_standard_accounts" .!= True

data Account = Account
  { accountBookId :: Text
  , accountId :: Text
  , accountType :: Text
  , accountAsset :: Text
  , accountPretax :: Scientific
  , accountComment :: Maybe Text
  }
  deriving (Eq, Show, Generic)

instance FromRow Account where
  fromRow = Account <$> field <*> field <*> field <*> field <*> field <*> field

instance ToJSON Account where
  toJSON Account
    { accountBookId
    , accountId
    , accountType
    , accountAsset
    , accountPretax
    , accountComment
    } =
    object
      [ "book_id" .= accountBookId
      , "id" .= accountId
      , "type" .= accountType
      , "asset" .= accountAsset
      , "pretax" .= accountPretax
      , "comment" .= accountComment
      ]

data NewAccount = NewAccount
  { newAccountId :: Text
  , newAccountType :: Text
  , newAccountAsset :: Text
  , newAccountPretax :: Scientific
  , newAccountComment :: Maybe Text
  , newAccountOpeningBalance :: Maybe Scientific
  , newAccountOpeningDate :: Maybe Day
  }
  deriving (Eq, Show, Generic)

instance FromJSON NewAccount where
  parseJSON =
    withObject "NewAccount" $ \o ->
      NewAccount
        <$> o .: "id"
        <*> o .: "type"
        <*> o .: "asset"
        <*> o .:? "pretax" .!= 1
        <*> o .:? "comment"
        <*> o .:? "opening_balance"
        <*> o .:? "opening_date"

data TransactionLine = TransactionLine
  { lineAccount :: Text
  , lineAmount :: Scientific
  , lineComment :: Maybe Text
  }
  deriving (Eq, Show, Generic)

instance FromJSON TransactionLine where
  parseJSON =
    withObject "TransactionLine" $ \o ->
      TransactionLine
        <$> o .: "account"
        <*> o .: "amount"
        <*> o .:? "comment"

data NewTransaction = NewTransaction
  { transactionDate :: Text
  , transactionResolved :: Bool
  , transactionComment :: Maybe Text
  , transactionLines :: [TransactionLine]
  }
  deriving (Eq, Show, Generic)

instance FromJSON NewTransaction where
  parseJSON =
    withObject "NewTransaction" $ \o ->
      NewTransaction
        <$> o .: "date"
        <*> o .:? "resolved" .!= True
        <*> o .:? "comment"
        <*> o .: "lines"

data CreatedTransaction = CreatedTransaction
  { createdBookId :: Text
  , createdXid :: Int
  , createdResolved :: Bool
  }
  deriving (Eq, Show, Generic)

instance ToJSON CreatedTransaction where
  toJSON CreatedTransaction{createdBookId, createdXid, createdResolved} =
    object
      [ "book_id" .= createdBookId
      , "xid" .= createdXid
      , "resolved" .= createdResolved
      ]

data LedgerLineUpdate = LedgerLineUpdate
  { updateLineDate :: Day
  , updateLineDescription :: Text
  }
  deriving (Eq, Show, Generic)

instance FromJSON LedgerLineUpdate where
  parseJSON =
    withObject "LedgerLineUpdate" $ \o ->
      LedgerLineUpdate
        <$> o .: "date"
        <*> o .: "description"

data LedgerEntry = LedgerEntry
  { ledgerDate :: Day
  , ledgerXid :: Int
  , ledgerAccount :: Maybe Text
  , ledgerDescription :: Maybe Text
  , ledgerTransfer :: Maybe Text
  , ledgerReconciled :: Bool
  , ledgerAmount :: Scientific
  , ledgerBalance :: Maybe Scientific
  , ledgerLineCount :: Int
  , ledgerSplitLines :: [LedgerSplitLine]
  }
  deriving (Eq, Show, Generic)

data LedgerRow = LedgerRow
  { rowDate :: Day
  , rowXid :: Int
  , rowAccount :: Text
  , rowDescription :: Maybe Text
  , rowTransfer :: Maybe Text
  , rowReconciled :: Bool
  , rowAmount :: Scientific
  , rowBalance :: Maybe Scientific
  , rowLineCount :: Int
  }
  deriving (Eq, Show, Generic)

instance FromRow LedgerRow where
  fromRow =
    LedgerRow
      <$> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field

data LedgerSplitLine = LedgerSplitLine
  { splitAccount :: Text
  , splitDescription :: Maybe Text
  , splitAmount :: Scientific
  }
  deriving (Eq, Show, Generic)

data LedgerSplitLineRow = LedgerSplitLineRow
  { splitRowXid :: Int
  , splitRowLine :: LedgerSplitLine
  }
  deriving (Eq, Show, Generic)

instance FromRow LedgerSplitLineRow where
  fromRow =
    LedgerSplitLineRow
      <$> field
      <*> (LedgerSplitLine <$> field <*> field <*> field)

instance ToJSON LedgerSplitLine where
  toJSON LedgerSplitLine{splitAccount, splitDescription, splitAmount} =
    object
      [ "account" .= splitAccount
      , "description" .= splitDescription
      , "amount" .= splitAmount
      ]

instance ToJSON LedgerEntry where
  toJSON LedgerEntry
    { ledgerDate
    , ledgerXid
    , ledgerAccount
    , ledgerDescription
    , ledgerTransfer
    , ledgerReconciled
    , ledgerAmount
    , ledgerBalance
    , ledgerLineCount
    , ledgerSplitLines
    } =
    object
      [ "date" .= ledgerDate
      , "xid" .= ledgerXid
      , "account" .= ledgerAccount
      , "description" .= ledgerDescription
      , "transfer" .= ledgerTransfer
      , "reconciled" .= ledgerReconciled
      , "amount" .= ledgerAmount
      , "balance" .= ledgerBalance
      , "split" .= (ledgerLineCount > 2)
      , "split_lines" .= ledgerSplitLines
      ]

data BalanceRow = BalanceRow
  { balanceBookId :: Text
  , balanceAccount :: Text
  , balanceOriginalCurrency :: Maybe Text
  , balancePretax :: Maybe Scientific
  , balancePosttax :: Maybe Scientific
  }
  deriving (Eq, Show, Generic)

instance FromRow BalanceRow where
  fromRow = BalanceRow <$> field <*> field <*> field <*> field <*> field

instance ToJSON BalanceRow where
  toJSON BalanceRow
    { balanceBookId
    , balanceAccount
    , balanceOriginalCurrency
    , balancePretax
    , balancePosttax
    } =
    object
      [ "book_id" .= balanceBookId
      , "account" .= balanceAccount
      , "origcurrency" .= balanceOriginalCurrency
      , "pretax" .= balancePretax
      , "posttax" .= balancePosttax
      ]

data ReportRow = ReportRow
  { reportBookId :: Text
  , reportSection :: Text
  , reportSectionOrder :: Int
  , reportRowOrder :: Int
  , reportRowKind :: Text
  , reportAccount :: Text
  , reportAccountType :: Maybe Text
  , reportOriginalCurrency :: Maybe Text
  , reportPretax :: Maybe Scientific
  , reportPosttax :: Maybe Scientific
  }
  deriving (Eq, Show, Generic)

instance FromRow ReportRow where
  fromRow =
    ReportRow
      <$> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field

instance ToJSON ReportRow where
  toJSON ReportRow
    { reportBookId
    , reportSection
    , reportSectionOrder
    , reportRowOrder
    , reportRowKind
    , reportAccount
    , reportAccountType
    , reportOriginalCurrency
    , reportPretax
    , reportPosttax
    } =
    object
      [ "book_id" .= reportBookId
      , "section" .= reportSection
      , "section_order" .= reportSectionOrder
      , "row_order" .= reportRowOrder
      , "row_kind" .= reportRowKind
      , "account" .= reportAccount
      , "account_type" .= reportAccountType
      , "origcurrency" .= reportOriginalCurrency
      , "pretax" .= reportPretax
      , "posttax" .= reportPosttax
      ]

data TrialBalanceRow = TrialBalanceRow
  { trialBookId :: Text
  , trialRowOrder :: Int
  , trialRowKind :: Text
  , trialAccount :: Text
  , trialAccountType :: Maybe Text
  , trialOriginalCurrency :: Maybe Text
  , trialDebit :: Maybe Scientific
  , trialCredit :: Maybe Scientific
  }
  deriving (Eq, Show, Generic)

instance FromRow TrialBalanceRow where
  fromRow =
    TrialBalanceRow
      <$> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field

instance ToJSON TrialBalanceRow where
  toJSON TrialBalanceRow
    { trialBookId
    , trialRowOrder
    , trialRowKind
    , trialAccount
    , trialAccountType
    , trialOriginalCurrency
    , trialDebit
    , trialCredit
    } =
    object
      [ "book_id" .= trialBookId
      , "row_order" .= trialRowOrder
      , "row_kind" .= trialRowKind
      , "account" .= trialAccount
      , "account_type" .= trialAccountType
      , "origcurrency" .= trialOriginalCurrency
      , "debit" .= trialDebit
      , "credit" .= trialCredit
      ]

data GeneralJournalRow = GeneralJournalRow
  { journalBookId :: Text
  , journalDate :: Day
  , journalXid :: Int
  , journalDescription :: Maybe Text
  , journalReconciled :: Bool
  , journalLineOrder :: Int
  , journalLineId :: Int
  , journalAccount :: Text
  , journalAccountType :: Text
  , journalMemo :: Maybe Text
  , journalDebit :: Maybe Scientific
  , journalCredit :: Maybe Scientific
  }
  deriving (Eq, Show, Generic)

instance FromRow GeneralJournalRow where
  fromRow =
    GeneralJournalRow
      <$> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field

instance ToJSON GeneralJournalRow where
  toJSON GeneralJournalRow
    { journalBookId
    , journalDate
    , journalXid
    , journalDescription
    , journalReconciled
    , journalLineOrder
    , journalLineId
    , journalAccount
    , journalAccountType
    , journalMemo
    , journalDebit
    , journalCredit
    } =
    object
      [ "book_id" .= journalBookId
      , "date" .= journalDate
      , "xid" .= journalXid
      , "description" .= journalDescription
      , "reconciled" .= journalReconciled
      , "line_order" .= journalLineOrder
      , "line_id" .= journalLineId
      , "account" .= journalAccount
      , "account_type" .= journalAccountType
      , "memo" .= journalMemo
      , "debit" .= journalDebit
      , "credit" .= journalCredit
      ]

type API =
       "health" :> Get '[JSON] Health
  :<|> "books" :> Get '[JSON] [Book]
  :<|> "books" :> ReqBody '[JSON] NewBook :> PostCreated '[JSON] Book
  :<|> "books" :> Capture "book_id" Text :> "accounts" :> Get '[JSON] [Account]
  :<|> "books" :> Capture "book_id" Text :> "accounts"
        :> ReqBody '[JSON] NewAccount
        :> PostCreated '[JSON] Account
  :<|> "books" :> Capture "book_id" Text :> "transactions"
        :> ReqBody '[JSON] NewTransaction
        :> PostCreated '[JSON] CreatedTransaction
  :<|> "books" :> Capture "book_id" Text :> "transactions"
        :> Capture "xid" Int
        :> ReqBody '[JSON] NewTransaction
        :> Verb 'PATCH 204 '[JSON] NoContent
  :<|> "books" :> Capture "book_id" Text :> "transactions"
        :> Capture "xid" Int
        :> "lines"
        :> Capture "account_id" Text
        :> ReqBody '[JSON] LedgerLineUpdate
        :> Verb 'PATCH 204 '[JSON] NoContent
  :<|> "books" :> Capture "book_id" Text :> "ledger"
        :> Get '[JSON] [LedgerEntry]
  :<|> "books" :> Capture "book_id" Text :> "ledger"
        :> Capture "account_id" Text
        :> Get '[JSON] [LedgerEntry]
  :<|> "books" :> Capture "book_id" Text :> "reports" :> "balance-sheet"
        :> QueryParam "as_of" Day
        :> Get '[JSON] [ReportRow]
  :<|> "books" :> Capture "book_id" Text :> "reports" :> "trial-balance"
        :> QueryParam "as_of" Day
        :> Get '[JSON] [TrialBalanceRow]
  :<|> "books" :> Capture "book_id" Text :> "reports" :> "profit-loss"
        :> QueryParam "from" Day
        :> QueryParam "to" Day
        :> Get '[JSON] [ReportRow]
  :<|> "books" :> Capture "book_id" Text :> "reports" :> "cash-flow"
        :> QueryParam "from" Day
        :> QueryParam "to" Day
        :> Get '[JSON] [ReportRow]
  :<|> "books" :> Capture "book_id" Text :> "reports" :> "general-journal"
        :> Get '[JSON] [GeneralJournalRow]
  :<|> "books" :> Capture "book_id" Text :> "balance-sheet"
        :> QueryParam "as_of" Day
        :> Get '[JSON] [BalanceRow]
  :<|> Raw

api :: Proxy API
api = Proxy

main :: IO ()
main = do
  connString <-
    BS.pack . fromMaybe "dbname=finances"
      <$> lookupEnv "PLUTUS_DATABASE_URL"
  port <-
    maybe 8080 (fromMaybe 8080 . readMaybe)
      <$> lookupEnv "PLUTUS_PORT"
  putStrLn ("plutus-server listening on http://127.0.0.1:" <> show port)
  putStrLn "using PLUTUS_DATABASE_URL, defaulting to dbname=finances"
  run port (serve api (server App{appConnectionString = connString}))

server :: App -> Server API
server app =
       getHealth app
  :<|> listBooks app
  :<|> createBook app
  :<|> listAccounts app
  :<|> createAccount app
  :<|> createTransaction app
  :<|> updateTransaction app
  :<|> updateLedgerLine app
  :<|> getFullLedger app
  :<|> getLedger app
  :<|> getBalanceSheetReport app
  :<|> getTrialBalanceReport app
  :<|> getProfitLossReport app
  :<|> getCashFlowReport app
  :<|> getGeneralJournal app
  :<|> getBalanceSheet app
  :<|> Tagged frontendApp

frontendApp :: Wai.Application
frontendApp req send =
  case Wai.pathInfo req of
    [] ->
      serveFile "text/html; charset=utf-8" "frontend/index.html"

    ["index.html"] ->
      serveFile "text/html; charset=utf-8" "frontend/index.html"

    ["app.js"] ->
      serveFile "application/javascript; charset=utf-8" "frontend/app.js"

    ["style.css"] ->
      serveFile "text/css; charset=utf-8" "frontend/style.css"

    _ ->
      send $
        Wai.responseLBS
          status404
          [(hContentType, "text/plain; charset=utf-8")]
          "not found"
  where
    serveFile mimeType path =
      send $
        Wai.responseFile
          status200
          [(hContentType, mimeType)]
          path
          Nothing

getHealth :: App -> Handler Health
getHealth app = do
  runDb app $ \conn -> do
    _ <- query_ conn "SELECT 1 :: int" :: IO [Only Int]
    pure ()
  pure Health{healthStatus = "ok"}

listBooks :: App -> Handler [Book]
listBooks app =
  runDb app $ \conn ->
    query_
      conn
      "SELECT id, name, reporting_asset FROM books ORDER BY id"

createBook :: App -> NewBook -> Handler Book
createBook app NewBook
  { newBookId
  , newBookName
  , newBookReportingAsset
  , newBookCreateStandardAccounts
  } =
  runDb app $ \conn -> withTransaction conn $ do
    _ <-
      execute
        conn
        "INSERT INTO books (id, name, reporting_asset) VALUES (?, ?, ?)"
        (newBookId, newBookName, newBookReportingAsset)
    when newBookCreateStandardAccounts $ do
      _ <-
        executeMany
        conn
        "INSERT INTO accts (book_id, id, type, atype) VALUES (?, ?, ?, ?)"
        [ (newBookId, "Opening Balance" :: Text, "Q" :: Text, newBookReportingAsset)
        , (newBookId, "Income" :: Text, "I" :: Text, newBookReportingAsset)
        , (newBookId, "Expenses" :: Text, "E" :: Text, newBookReportingAsset)
        ]
      pure ()
    pure
      Book
        { bookId = newBookId
        , bookName = newBookName
        , bookReportingAsset = newBookReportingAsset
        }

listAccounts :: App -> Text -> Handler [Account]
listAccounts app bookId =
  runDb app $ \conn ->
    query
      conn
      "SELECT book_id, id, type, atype, pretax, comment \
      \FROM accts WHERE book_id = ? ORDER BY type, id"
      (Only bookId)

createAccount :: App -> Text -> NewAccount -> Handler Account
createAccount app bookId newAccount@NewAccount{newAccountOpeningBalance} = do
  case (newAccountOpeningBalance, newAccountOpeningDate newAccount) of
    (Just _, Nothing) ->
      throwError
        err400
          { errBody = "opening_date is required when opening_balance is set"
          }
    _ -> pure ()

  runDb app $ \conn -> withTransaction conn $ do
    _ <-
      execute
        conn
        "INSERT INTO accts (book_id, id, type, atype, pretax, comment) \
        \VALUES (?, ?, ?, ?, ?, ?)"
        ( bookId
        , newAccountId newAccount
        , newAccountType newAccount
        , newAccountAsset newAccount
        , newAccountPretax newAccount
        , newAccountComment newAccount
        )

    case (newAccountOpeningBalance, newAccountOpeningDate newAccount) of
      (Just openingBalance, Just openingDate) ->
        insertTransaction
          conn
          bookId
          (Text.pack (show openingDate))
          True
          (Just "Opening balance")
          [ TransactionLine
              { lineAccount = newAccountId newAccount
              , lineAmount = openingBalance
              , lineComment = Just "Opening balance"
              }
          , TransactionLine
              { lineAccount = "Opening Balance"
              , lineAmount = negate openingBalance
              , lineComment = Just "Opening balance"
              }
          ]
          >> pure ()
      _ -> pure ()

    pure
      Account
        { accountBookId = bookId
        , accountId = newAccountId newAccount
        , accountType = newAccountType newAccount
        , accountAsset = newAccountAsset newAccount
        , accountPretax = newAccountPretax newAccount
        , accountComment = newAccountComment newAccount
        }

createTransaction :: App -> Text -> NewTransaction -> Handler CreatedTransaction
createTransaction app bookId NewTransaction
  { transactionDate
  , transactionResolved
  , transactionComment
  , transactionLines
  } = do
  unless (not (null transactionLines)) $
    throwError err400{errBody = "transactions require at least one line"}

  xid <-
    runDb app $ \conn ->
      withTransaction conn $
        insertTransaction
          conn
          bookId
          transactionDate
          transactionResolved
          transactionComment
          transactionLines

  pure
    CreatedTransaction
      { createdBookId = bookId
      , createdXid = xid
      , createdResolved = transactionResolved
      }

updateTransaction :: App -> Text -> Int -> NewTransaction -> Handler NoContent
updateTransaction app bookId xid NewTransaction
  { transactionDate
  , transactionResolved
  , transactionComment
  , transactionLines
  } = do
  unless (not (null transactionLines)) $
    throwError err400{errBody = "transactions require at least one line"}

  unless (sum (map lineAmount transactionLines) == 0) $
    throwError err400{errBody = "transaction lines must balance"}

  let (normalisedComment, normalisedLines) =
        normaliseTransaction transactionComment transactionLines

  updated <-
    runDb app $ \conn ->
      withTransaction conn $ do
        headerRows <-
          execute
            conn
            "UPDATE xactions \
            \SET date = ?::timestamp, comment = ? \
            \WHERE book_id = ? AND xid = ?"
            (transactionDate, normalisedComment, bookId, xid)

        when (headerRows > 0) $ do
          _ <-
            execute
              conn
              "DELETE FROM xaction_unresolved WHERE book_id = ? AND xid = ?"
              (bookId, xid)
          _ <-
            execute
              conn
              "DELETE FROM xaction_bits WHERE book_id = ? AND xid = ?"
              (bookId, xid)

          forM_ normalisedLines $
            \TransactionLine{lineAccount, lineAmount, lineComment} ->
              execute
                conn
                "INSERT INTO xaction_bits (book_id, xid, acct, amt, comment) \
                \VALUES (?, ?, ?, ?, ?)"
                (bookId, xid, lineAccount, lineAmount, lineComment)

          unless transactionResolved $
            execute
              conn
              "INSERT INTO xaction_unresolved (book_id, xid) VALUES (?, ?)"
              (bookId, xid)
              >> pure ()

        pure headerRows

  if updated == 0 then
    throwError
      err404
        { errBody = "transaction not found"
        , errHeaders = [(hContentType, "text/plain; charset=utf-8")]
        }

  else
    pure NoContent

updateLedgerLine
  :: App
  -> Text
  -> Int
  -> Text
  -> LedgerLineUpdate
  -> Handler NoContent
updateLedgerLine app bookId xid accountId LedgerLineUpdate
  { updateLineDate
  , updateLineDescription
  } = do
  updated <-
    runDb app $ \conn ->
      withTransaction conn $ do
        lineExists <-
          query
            conn
            "SELECT EXISTS ( \
            \  SELECT 1 FROM xaction_bits \
            \  WHERE book_id = ? AND xid = ? AND acct = ? \
            \)"
            (bookId, xid, accountId)
            :: IO [Only Bool]

        lineCount <-
          query
            conn
            "SELECT count(*) FROM xaction_bits WHERE book_id = ? AND xid = ?"
            (bookId, xid)
            :: IO [Only Int]

        let exists =
              case lineExists of
                [Only value] -> value
                _ -> False

            isSimple =
              case lineCount of
                [Only count_] -> count_ == 2
                _ -> False

        when exists $ do
          if isSimple
            then do
              _ <-
                execute
                  conn
                  "UPDATE xaction_bits \
                  \SET comment = NULL \
                  \WHERE book_id = ? AND xid = ?"
                  (bookId, xid)
              pure ()
            else do
              _ <-
                execute
                  conn
                  "UPDATE xaction_bits \
                  \SET comment = ? \
                  \WHERE book_id = ? AND xid = ? AND acct = ?"
                  (updateLineDescription, bookId, xid, accountId)
              pure ()

          _ <-
            execute
              conn
              "UPDATE xactions \
              \SET date = ?::timestamp, comment = CASE WHEN ? THEN ? ELSE comment END \
              \WHERE book_id = ? AND xid = ?"
              (updateLineDate, isSimple, updateLineDescription, bookId, xid)
          pure ()

        pure
          ( if exists then
              1 :: Int
            else
              0
          )

  if updated == 0 then
    throwError
      err404
        { errBody = "ledger line not found"
        , errHeaders = [(hContentType, "text/plain; charset=utf-8")]
        }

  else
    pure NoContent

getLedger :: App -> Text -> Text -> Handler [LedgerEntry]
getLedger app bookId accountId =
  runDb app $ \conn -> do
    rows <-
      query
        conn
        "SELECT \
        \CAST (xactions.date AS date), \
        \xaction_bits.xid, \
        \xaction_bits.acct, \
        \COALESCE(xaction_bits.comment, xactions.comment), \
        \CASE WHEN line_counts.line_count = 2 THEN other_bits.acct ELSE NULL END, \
        \NOT EXISTS ( \
        \  SELECT 1 FROM xaction_unresolved \
        \  WHERE xaction_unresolved.book_id = xaction_bits.book_id \
        \    AND xaction_unresolved.xid = xaction_bits.xid \
        \), \
        \xaction_bits.amt, \
        \sum(xaction_bits.amt) OVER ( \
        \  ORDER BY xactions.date, xaction_bits.xid, xaction_bits.id \
        \), \
        \line_counts.line_count \
        \FROM xaction_bits \
        \JOIN xactions \
        \  ON xactions.book_id = xaction_bits.book_id \
        \ AND xactions.xid = xaction_bits.xid \
        \JOIN ( \
        \  SELECT book_id, xid, count(*) AS line_count \
        \  FROM xaction_bits \
        \  GROUP BY book_id, xid \
        \) AS line_counts \
        \  ON line_counts.book_id = xaction_bits.book_id \
        \ AND line_counts.xid = xaction_bits.xid \
        \LEFT JOIN xaction_bits AS other_bits \
        \  ON other_bits.book_id = xaction_bits.book_id \
        \ AND other_bits.xid = xaction_bits.xid \
        \ AND line_counts.line_count = 2 \
        \ AND other_bits.acct <> xaction_bits.acct \
        \WHERE xaction_bits.book_id = ? \
        \  AND xaction_bits.acct = ? \
        \ORDER BY xactions.date, xaction_bits.xid, xaction_bits.id"
        (bookId, accountId)
    splitRows <-
      query
        conn
        "SELECT \
        \xaction_bits.xid, \
        \xaction_bits.acct, \
        \COALESCE(xaction_bits.comment, xactions.comment), \
        \xaction_bits.amt \
        \FROM xaction_bits \
        \JOIN xactions \
        \  ON xactions.book_id = xaction_bits.book_id \
        \ AND xactions.xid = xaction_bits.xid \
        \JOIN ( \
        \  SELECT book_id, xid, count(*) AS line_count \
        \  FROM xaction_bits \
        \  GROUP BY book_id, xid \
        \) AS line_counts \
        \  ON line_counts.book_id = xaction_bits.book_id \
        \ AND line_counts.xid = xaction_bits.xid \
        \WHERE xaction_bits.book_id = ? \
        \  AND line_counts.line_count > 2 \
        \  AND EXISTS ( \
        \    SELECT 1 FROM xaction_bits AS selected_bits \
        \    WHERE selected_bits.book_id = xaction_bits.book_id \
        \      AND selected_bits.xid = xaction_bits.xid \
        \      AND selected_bits.acct = ? \
        \  ) \
        \ORDER BY xaction_bits.xid, xaction_bits.id"
        (bookId, accountId)
    pure (ledgerEntries rows splitRows)

getFullLedger :: App -> Text -> Handler [LedgerEntry]
getFullLedger app bookId =
  runDb app $ \conn -> do
    rows <-
      query
        conn
        "SELECT \
        \CAST (xactions.date AS date), \
        \xaction_bits.xid, \
        \xaction_bits.acct, \
        \COALESCE(xaction_bits.comment, xactions.comment), \
        \CASE WHEN line_counts.line_count = 2 THEN other_bits.acct ELSE NULL END, \
        \NOT EXISTS ( \
        \  SELECT 1 FROM xaction_unresolved \
        \  WHERE xaction_unresolved.book_id = xaction_bits.book_id \
        \    AND xaction_unresolved.xid = xaction_bits.xid \
        \), \
        \xaction_bits.amt, \
        \sum(xaction_bits.amt) OVER ( \
        \  PARTITION BY xaction_bits.acct \
        \  ORDER BY xactions.date, xaction_bits.xid, xaction_bits.id \
        \), \
        \line_counts.line_count \
        \FROM xaction_bits \
        \JOIN xactions \
        \  ON xactions.book_id = xaction_bits.book_id \
        \ AND xactions.xid = xaction_bits.xid \
        \JOIN ( \
        \  SELECT book_id, xid, count(*) AS line_count \
        \  FROM xaction_bits \
        \  GROUP BY book_id, xid \
        \) AS line_counts \
        \  ON line_counts.book_id = xaction_bits.book_id \
        \ AND line_counts.xid = xaction_bits.xid \
        \LEFT JOIN xaction_bits AS other_bits \
        \  ON other_bits.book_id = xaction_bits.book_id \
        \ AND other_bits.xid = xaction_bits.xid \
        \ AND line_counts.line_count = 2 \
        \ AND other_bits.acct <> xaction_bits.acct \
        \WHERE xaction_bits.book_id = ? \
        \ORDER BY xactions.date, xaction_bits.xid, xaction_bits.id"
        (Only bookId)
    splitRows <-
      query
        conn
        "SELECT \
        \xaction_bits.xid, \
        \xaction_bits.acct, \
        \COALESCE(xaction_bits.comment, xactions.comment), \
        \xaction_bits.amt \
        \FROM xaction_bits \
        \JOIN xactions \
        \  ON xactions.book_id = xaction_bits.book_id \
        \ AND xactions.xid = xaction_bits.xid \
        \JOIN ( \
        \  SELECT book_id, xid, count(*) AS line_count \
        \  FROM xaction_bits \
        \  GROUP BY book_id, xid \
        \) AS line_counts \
        \  ON line_counts.book_id = xaction_bits.book_id \
        \ AND line_counts.xid = xaction_bits.xid \
        \WHERE xaction_bits.book_id = ? \
        \  AND line_counts.line_count > 2 \
        \ORDER BY xaction_bits.xid, xaction_bits.id"
        (Only bookId)
    pure (ledgerEntries rows splitRows)

ledgerEntries :: [LedgerRow] -> [LedgerSplitLineRow] -> [LedgerEntry]
ledgerEntries rows splitRows =
  let
    splitMap =
      foldr
        (\LedgerSplitLineRow{splitRowXid, splitRowLine} ->
          Map.insertWith (++) splitRowXid [splitRowLine]
        )
        Map.empty
        splitRows
  in
    map (ledgerEntry splitMap) rows

ledgerEntry :: Map.Map Int [LedgerSplitLine] -> LedgerRow -> LedgerEntry
ledgerEntry splitMap LedgerRow
  { rowDate
  , rowXid
  , rowAccount
  , rowDescription
  , rowTransfer
  , rowReconciled
  , rowAmount
  , rowBalance
  , rowLineCount
  } =
  LedgerEntry
    { ledgerDate = rowDate
    , ledgerXid = rowXid
    , ledgerAccount = Just rowAccount
    , ledgerDescription = rowDescription
    , ledgerTransfer = rowTransfer
    , ledgerReconciled = rowReconciled
    , ledgerAmount = rowAmount
    , ledgerBalance = rowBalance
    , ledgerLineCount = rowLineCount
    , ledgerSplitLines = Map.findWithDefault [] rowXid splitMap
    }

getBalanceSheet :: App -> Text -> Maybe Day -> Handler [BalanceRow]
getBalanceSheet app bookId asOf =
  runDb app $ \conn ->
    case asOf of
      Nothing ->
        query
          conn
          "SELECT book_id, account, origcurrency, pretax, posttax \
          \FROM balance_sheet WHERE book_id = ? ORDER BY account"
          (Only bookId)
      Just day ->
        query
          conn
          "SELECT book_id, account, origcurrency, pretax, posttax \
          \FROM bsheet(?, ?) ORDER BY account"
          (bookId, day)

getBalanceSheetReport :: App -> Text -> Maybe Day -> Handler [ReportRow]
getBalanceSheetReport app bookId asOf =
  runDb app $ \conn ->
    case asOf of
      Nothing ->
        query
          conn
          "SELECT book_id, section, section_order, row_order, row_kind, \
          \account, account_type, origcurrency, pretax, posttax \
          \FROM balance_sheet_report \
          \WHERE book_id = ? \
          \ORDER BY section_order, row_order, account"
          (Only bookId)
      Just day ->
        query
          conn
          "SELECT book_id, section, section_order, row_order, row_kind, \
          \account, account_type, origcurrency, pretax, posttax \
          \FROM bsheet_report(?, ?) \
          \ORDER BY section_order, row_order, account"
          (bookId, day)

getTrialBalanceReport :: App -> Text -> Maybe Day -> Handler [TrialBalanceRow]
getTrialBalanceReport app bookId asOf =
  runDb app $ \conn ->
    case asOf of
      Nothing ->
        query
          conn
          "SELECT book_id, row_order, row_kind, account, account_type, \
          \origcurrency, debit, credit \
          \FROM trial_balance_report \
          \WHERE book_id = ? \
          \ORDER BY row_order, account"
          (Only bookId)
      Just day ->
        query
          conn
          "SELECT book_id, row_order, row_kind, account, account_type, \
          \origcurrency, debit, credit \
          \FROM tb_report(?, ?) \
          \ORDER BY row_order, account"
          (bookId, day)

getProfitLossReport :: App -> Text -> Maybe Day -> Maybe Day -> Handler [ReportRow]
getProfitLossReport app bookId startDate endDate =
  runDb app $ \conn ->
    case (startDate, endDate) of
      (Nothing, Nothing) ->
        query
          conn
          "SELECT book_id, section, section_order, row_order, row_kind, \
          \account, account_type, origcurrency, pretax, posttax \
          \FROM profit_loss_report \
          \WHERE book_id = ? \
          \ORDER BY section_order, row_order, account"
          (Only bookId)
      _ ->
        query
          conn
          "SELECT book_id, section, section_order, row_order, row_kind, \
          \account, account_type, origcurrency, pretax, posttax \
          \FROM pl_report(?, ?, ?) \
          \ORDER BY section_order, row_order, account"
          (bookId, startDate, endDate)

getCashFlowReport :: App -> Text -> Maybe Day -> Maybe Day -> Handler [ReportRow]
getCashFlowReport app bookId startDate endDate =
  runDb app $ \conn ->
    case (startDate, endDate) of
      (Nothing, Nothing) ->
        query
          conn
          "SELECT book_id, section, section_order, row_order, row_kind, \
          \account, account_type, origcurrency, pretax, posttax \
          \FROM cash_flow_report \
          \WHERE book_id = ? \
          \ORDER BY section_order, row_order, account"
          (Only bookId)
      _ ->
        query
          conn
          "SELECT book_id, section, section_order, row_order, row_kind, \
          \account, account_type, origcurrency, pretax, posttax \
          \FROM cf_report(?, ?, ?) \
          \ORDER BY section_order, row_order, account"
          (bookId, startDate, endDate)

getGeneralJournal :: App -> Text -> Handler [GeneralJournalRow]
getGeneralJournal app bookId =
  runDb app $ \conn ->
    query
      conn
      "SELECT book_id, date, xid, description, reconciled, line_order, \
      \line_id, account, account_type, memo, debit, credit \
      \FROM general_journal \
      \WHERE book_id = ? \
      \ORDER BY date, xid, line_order, line_id"
      (Only bookId)

insertTransaction
  :: Connection
  -> Text
  -> Text
  -> Bool
  -> Maybe Text
  -> [TransactionLine]
  -> IO Int
insertTransaction conn bookId transactionDate resolved transactionComment lines_ = do
  let (normalisedComment, normalisedLines) =
        normaliseTransaction transactionComment lines_

  [Only xid] <-
    query
      conn
      "INSERT INTO xactions (book_id, date, comment) \
      \VALUES (?, ?::timestamp, ?) RETURNING xid"
      (bookId, transactionDate, normalisedComment)

  forM_ normalisedLines $ \TransactionLine{lineAccount, lineAmount, lineComment} ->
    execute
      conn
      "INSERT INTO xaction_bits (book_id, xid, acct, amt, comment) \
      \VALUES (?, ?, ?, ?, ?)"
      (bookId, xid, lineAccount, lineAmount, lineComment)

  unless resolved $
    execute
      conn
      "INSERT INTO xaction_unresolved (book_id, xid) VALUES (?, ?)"
      (bookId, xid)
      >> pure ()

  pure xid

normaliseTransaction :: Maybe Text -> [TransactionLine] -> (Maybe Text, [TransactionLine])
normaliseTransaction transactionComment lines_ =
  let headerComment =
        case nonBlank transactionComment of
          Just value -> Just value
          Nothing -> sharedLineComment lines_
  in
  case lines_ of
    [_, _] ->
      ( simpleTransactionComment headerComment lines_
      , map (\line -> line{lineComment = Nothing}) lines_
      )
    _ ->
      ( headerComment
      , map (removeDuplicateLineComment headerComment) lines_
      )

simpleTransactionComment :: Maybe Text -> [TransactionLine] -> Maybe Text
simpleTransactionComment headerComment lines_ =
  case headerComment of
    Just value -> Just value
    Nothing -> firstLineComment lines_

firstLineComment :: [TransactionLine] -> Maybe Text
firstLineComment lines_ =
  case lines_ of
    [] ->
      Nothing
    line : rest ->
      case nonBlank (lineComment line) of
        Just value -> Just value
        Nothing -> firstLineComment rest

sharedLineComment :: [TransactionLine] -> Maybe Text
sharedLineComment lines_ =
  case lineComments lines_ of
    [] ->
      Nothing
    comment : rest
      | all (== comment) rest -> Just comment
    _ ->
      Nothing

lineComments :: [TransactionLine] -> [Text]
lineComments lines_ =
  case lines_ of
    [] ->
      []
    line : rest ->
      case nonBlank (lineComment line) of
        Just value -> value : lineComments rest
        Nothing -> lineComments rest

removeDuplicateLineComment :: Maybe Text -> TransactionLine -> TransactionLine
removeDuplicateLineComment transactionComment line =
  case (nonBlank transactionComment, nonBlank (lineComment line)) of
    (Just header, Just memo)
      | header == memo -> line{lineComment = Nothing}
    (_, Just memo) -> line{lineComment = Just memo}
    _ -> line{lineComment = Nothing}

nonBlank :: Maybe Text -> Maybe Text
nonBlank value =
  case Text.strip <$> value of
    Just stripped
      | stripped /= "" -> Just stripped
    _ -> Nothing

runDb :: App -> (Connection -> IO a) -> Handler a
runDb App{appConnectionString} action = do
  result <-
    liftIO $
      try $
        bracket
          (connectPostgreSQL appConnectionString)
          close
          action

  case result of
    Right value -> pure value
    Left (err :: SqlError) ->
      throwError
        err400
          { errBody = formatSqlError err
          , errHeaders = [(hContentType, "text/plain; charset=utf-8")]
          }

formatSqlError :: SqlError -> LBS.ByteString
formatSqlError err =
  let
    body =
      if BS.null (sqlErrorDetail err)
        then sqlErrorMsg err
        else BS.concat [sqlErrorMsg err, "\n", sqlErrorDetail err]
  in
    if BS.null body
      then LBS.pack (show err)
      else LBS.fromStrict body
