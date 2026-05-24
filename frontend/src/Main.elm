port module Main exposing (main)

import Browser
import Browser.Events as BrowserEvents
import Html exposing (Html)
import Html.Attributes as Attr
import Html.Events as Events
import Http
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import String
import Time
import Url.Builder as Url


port alertUser : String -> Cmd msg


main : Program () Model Msg
main =
    Browser.element
        { init = \_ -> ( initialModel, loadBooks )
        , update = update
        , subscriptions = subscriptions
        , view = view
        }


subscriptions : Model -> Sub Msg
subscriptions model =
    let
        autosave =
            if model.editDirty then
                Time.every 1000 AutoSaveTick

            else
                Sub.none

        columnResize =
            case model.resizingLedgerColumn of
                Just _ ->
                    Sub.batch
                        [ BrowserEvents.onMouseMove
                            (Decode.map DragLedgerColumnResize
                                (Decode.field "clientX" Decode.float)
                            )
                        , BrowserEvents.onMouseUp (Decode.succeed StopLedgerColumnResize)
                        ]

                Nothing ->
                    Sub.none
    in
    Sub.batch [ autosave, columnResize ]


type Page
    = LedgerPage
    | GeneralJournalPage
    | BalanceSheetPage
    | TrialBalancePage
    | ProfitLossPage
    | CashFlowPage
    | AddBookPage
    | AddAccountPage


type alias Book =
    { id : String
    , name : String
    , reportingAsset : String
    }


type alias Account =
    { bookId : String
    , id : String
    , accountType : String
    , asset : String
    , pretax : Float
    , comment : Maybe String
    }


type alias LedgerEntry =
    { date : String
    , xid : Int
    , account : Maybe String
    , description : Maybe String
    , transfer : Maybe String
    , reconciled : Bool
    , amount : Float
    , balance : Maybe Float
    , split : Bool
    , splitLines : List LedgerSplitLine
    }


type alias LedgerSplitLine =
    { account : String
    , description : Maybe String
    , amount : Float
    }


type LedgerRowKind
    = ParentLedgerRow
    | SplitLedgerRow


type alias LedgerRowSelection =
    { kind : LedgerRowKind
    , xid : Int
    , account : String
    }


type alias LedgerLineEdit =
    { xid : Int
    , account : String
    , date : String
    , description : String
    }


type alias LedgerColumn =
    { id : LedgerColumnId
    , label : String
    , className : String
    , defaultWidth : Float
    , minWidth : Float
    }


type LedgerColumnId
    = LedgerDateColumn
    | LedgerXidColumn
    | LedgerDescriptionColumn
    | LedgerTransferColumn
    | LedgerReconciledColumn
    | LedgerDepositColumn
    | LedgerWithdrawalColumn
    | LedgerBalanceColumn


type alias LedgerColumnWidth =
    { column : LedgerColumnId
    , width : Float
    }


type alias LedgerColumnResize =
    { column : LedgerColumnId
    , startX : Float
    , startWidth : Float
    }


type alias BalanceRow =
    { bookId : String
    , section : String
    , sectionOrder : Int
    , rowOrder : Int
    , rowKind : String
    , account : String
    , accountType : Maybe String
    , origcurrency : Maybe String
    , pretax : Maybe Float
    , posttax : Maybe Float
    }


type alias TrialBalanceRow =
    { bookId : String
    , rowOrder : Int
    , rowKind : String
    , account : String
    , accountType : Maybe String
    , origcurrency : Maybe String
    , debit : Maybe Float
    , credit : Maybe Float
    }


type alias GeneralJournalRow =
    { bookId : String
    , date : String
    , xid : Int
    , description : Maybe String
    , reconciled : Bool
    , lineOrder : Int
    , lineId : Int
    , account : String
    , accountType : String
    , memo : Maybe String
    , debit : Maybe Float
    , credit : Maybe Float
    }


type alias CreatedTransaction =
    { bookId : String
    , xid : Int
    , resolved : Bool
    }


type alias TransactionLineDraft =
    { account : String
    , amount : Float
    , memo : String
    }


type alias TransactionEditLine =
    { key : Int
    , account : String
    , memo : String
    , debit : String
    , credit : String
    , primary : Bool
    }


type alias TransactionEdit =
    { xid : Int
    , date : String
    , resolved : Bool
    , split : Bool
    , lines : List TransactionEditLine
    , nextKey : Int
    }


type alias SplitLineInput =
    { key : Int
    , account : String
    , memo : String
    , debit : String
    , credit : String
    }


type alias Model =
    { books : List Book
    , selectedBook : Maybe String
    , accounts : List Account
    , selectedAccount : Maybe String
    , ledger : List LedgerEntry
    , selectedLedgerRow : Maybe LedgerRowSelection
    , transactionEdit : Maybe TransactionEdit
    , editDirty : Bool
    , editIdleTicks : Int
    , ledgerEdits : List LedgerLineEdit
    , expandedSplits : List Int
    , ledgerColumnWidths : List LedgerColumnWidth
    , resizingLedgerColumn : Maybe LedgerColumnResize
    , balance : List BalanceRow
    , trialBalance : List TrialBalanceRow
    , journal : List GeneralJournalRow
    , page : Page
    , status : String
    , loading : Bool
    , bookIdInput : String
    , bookNameInput : String
    , bookAssetInput : String
    , accountIdInput : String
    , accountTypeInput : String
    , accountAssetInput : String
    , accountPretaxInput : String
    , accountOpeningBalanceInput : String
    , accountOpeningDateInput : String
    , reportDateInput : String
    , reportStartDateInput : String
    , reportEndDateInput : String
    , appendDateInput : String
    , appendMemoInput : String
    , appendOtherAccountInput : String
    , appendDebitInput : String
    , appendCreditInput : String
    , appendResolvedInput : Bool
    , appendSplitInput : Bool
    , splitRows : List SplitLineInput
    , nextSplitRowKey : Int
    }


initialModel : Model
initialModel =
    { books = []
    , selectedBook = Nothing
    , accounts = []
    , selectedAccount = Nothing
    , ledger = []
    , selectedLedgerRow = Nothing
    , transactionEdit = Nothing
    , editDirty = False
    , editIdleTicks = 0
    , ledgerEdits = []
    , expandedSplits = []
    , ledgerColumnWidths = []
    , resizingLedgerColumn = Nothing
    , balance = []
    , trialBalance = []
    , journal = []
    , page = LedgerPage
    , status = "Loading"
    , loading = True
    , bookIdInput = ""
    , bookNameInput = ""
    , bookAssetInput = "GBP"
    , accountIdInput = ""
    , accountTypeInput = "A"
    , accountAssetInput = "GBP"
    , accountPretaxInput = "1.0"
    , accountOpeningBalanceInput = ""
    , accountOpeningDateInput = ""
    , reportDateInput = ""
    , reportStartDateInput = ""
    , reportEndDateInput = ""
    , appendDateInput = ""
    , appendMemoInput = ""
    , appendOtherAccountInput = ""
    , appendDebitInput = ""
    , appendCreditInput = ""
    , appendResolvedInput = True
    , appendSplitInput = False
    , splitRows = [ emptySplitRow 1 ]
    , nextSplitRowKey = 2
    }


emptySplitRow : Int -> SplitLineInput
emptySplitRow key =
    { key = key
    , account = ""
    , memo = ""
    , debit = ""
    , credit = ""
    }


type Msg
    = GotBooks (Result Http.Error (List Book))
    | SelectBookMenu String
    | GotAccounts (Result Http.Error (List Account))
    | SelectAccountMenu String
    | SelectReport String
    | GotLedger (Result Http.Error (List LedgerEntry))
    | GotBalance (Result Http.Error (List BalanceRow))
    | GotTrialBalance (Result Http.Error (List TrialBalanceRow))
    | GotGeneralJournal (Result Http.Error (List GeneralJournalRow))
    | UpdateBookId String
    | UpdateBookName String
    | UpdateBookAsset String
    | SubmitBook
    | CreatedBook (Result Http.Error Book)
    | UpdateAccountId String
    | UpdateAccountType String
    | UpdateAccountAsset String
    | UpdateAccountPretax String
    | UpdateAccountOpeningBalance String
    | UpdateAccountOpeningDate String
    | SubmitAccount
    | CreatedAccount (Result Http.Error Account)
    | UpdateReportDate String
    | UpdateReportStartDate String
    | UpdateReportEndDate String
    | RefreshReport
    | UpdateAppendDate String
    | UpdateAppendMemo String
    | UpdateAppendOtherAccount String
    | UpdateAppendDebit String
    | UpdateAppendCredit String
    | UpdateAppendResolved Bool
    | ToggleAppendSplit
    | AddSplitRow
    | RemoveSplitRow Int
    | UpdateSplitAccount Int String
    | UpdateSplitMemo Int String
    | UpdateSplitDebit Int String
    | UpdateSplitCredit Int String
    | ToggleSplit Int
    | SelectLedgerRow LedgerRowSelection
    | UpdateTransactionDate String
    | UpdateTransactionMemo Int String
    | UpdateTransactionAccount Int String
    | UpdateTransactionDebit Int String
    | UpdateTransactionCredit Int String
    | AddTransactionSplitLine
    | RemoveTransactionLine Int
    | SaveSelectedTransaction
    | AutoSaveTick Time.Posix
    | SavedTransaction Int (Result Http.Error ())
    | UpdateLedgerDate Int String String
    | UpdateLedgerDescription Int String String
    | SubmitLedgerLine Int String
    | UpdatedLedgerLine (Result Http.Error ())
    | StartLedgerColumnResize LedgerColumnId Float
    | DragLedgerColumnResize Float
    | StopLedgerColumnResize
    | AppendTransaction
    | CreatedTransactionResponse (Result Http.Error CreatedTransaction)
    | RefreshAll


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        GotBooks result ->
            case result of
                Ok books ->
                    let
                        selected =
                            selectedBookAfterLoad model.selectedBook books
                    in
                    ( { model
                        | books = books
                        , selectedBook = selected
                        , loading = False
                        , status = "Ready"
                      }
                    , selected
                        |> Maybe.map loadAccounts
                        |> Maybe.withDefault Cmd.none
                    )

                Err err ->
                    ( setError err model, Cmd.none )

        SelectBookMenu value ->
            if value == addBookValue then
                ( { model | page = AddBookPage, status = "Add book" }, Cmd.none )

            else
                ( { model
                    | selectedBook = Just value
                    , selectedAccount = Nothing
                    , accounts = []
                    , ledger = []
                    , journal = []
                    , selectedLedgerRow = Nothing
                    , transactionEdit = Nothing
                    , editDirty = False
                    , editIdleTicks = 0
                    , ledgerEdits = []
                    , expandedSplits = []
                    , balance = []
                    , trialBalance = []
                    , appendOtherAccountInput = ""
                    , splitRows = [ emptySplitRow 1 ]
                    , nextSplitRowKey = 2
                    , loading = True
                    , status = "Loading book"
                  }
                , loadAccounts value
                )

        GotAccounts result ->
            case result of
                Ok accounts ->
                    let
                        selected =
                            selectedAccountAfterLoad model.selectedAccount accounts

                        cmds =
                            case ( model.selectedBook, selected, model.page ) of
                                ( Just bookId, Just accountId, LedgerPage ) ->
                                    loadLedger bookId accountId

                                ( Just _, Nothing, LedgerPage ) ->
                                    Cmd.none

                                ( Just bookId, _, GeneralJournalPage ) ->
                                    loadGeneralJournal bookId

                                ( Just bookId, _, BalanceSheetPage ) ->
                                    loadBalance bookId model.reportDateInput

                                ( Just bookId, _, TrialBalancePage ) ->
                                    loadTrialBalance bookId model.reportDateInput

                                ( Just bookId, _, ProfitLossPage ) ->
                                    loadProfitLoss
                                        bookId
                                        model.reportStartDateInput
                                        model.reportEndDateInput

                                ( Just bookId, _, CashFlowPage ) ->
                                    loadCashFlow
                                        bookId
                                        model.reportStartDateInput
                                        model.reportEndDateInput

                                _ ->
                                    Cmd.none
                    in
                    ( { model
                        | accounts = accounts
                        , selectedAccount = selected
                        , loading = False
                        , status = "Ready"
                      }
                    , cmds
                    )

                Err err ->
                    ( setError err model, Cmd.none )

        SelectAccountMenu value ->
            if value == addAccountValue then
                ( { model | page = AddAccountPage, status = "Add account" }, Cmd.none )

            else
                case model.selectedBook of
                    Just bookId ->
                        ( { model
                            | selectedAccount = Just value
                            , page = LedgerPage
                            , selectedLedgerRow = Nothing
                            , transactionEdit = Nothing
                            , editDirty = False
                            , editIdleTicks = 0
                            , ledgerEdits = []
                            , expandedSplits = []
                            , loading = True
                            , status = "Loading ledger"
                          }
                        , loadLedger bookId value
                        )

                    Nothing ->
                        ( model, Cmd.none )

        SelectReport value ->
            case ( value, model.selectedBook ) of
                ( "ledger", Just bookId ) ->
                    let
                        accountId =
                            selectedLedgerAccount model
                    in
                    if accountId == "" then
                        ( { model | page = LedgerPage, status = "Create or select an account" }
                        , Cmd.none
                        )

                    else
                        ( { model
                            | page = LedgerPage
                            , selectedAccount = Just accountId
                            , selectedLedgerRow = Nothing
                            , transactionEdit = Nothing
                            , editDirty = False
                            , editIdleTicks = 0
                            , ledgerEdits = []
                            , expandedSplits = []
                            , loading = True
                            , status = "Loading ledger"
                          }
                        , loadLedger bookId accountId
                        )

                ( "ledger", Nothing ) ->
                    ( { model | page = LedgerPage, status = "Select a book" }, Cmd.none )

                ( "general-journal", Just bookId ) ->
                    ( { model
                        | page = GeneralJournalPage
                        , selectedLedgerRow = Nothing
                        , transactionEdit = Nothing
                        , editDirty = False
                        , editIdleTicks = 0
                        , loading = True
                        , status = "Loading general journal"
                      }
                    , loadGeneralJournal bookId
                    )

                ( "general-journal", Nothing ) ->
                    ( { model | page = GeneralJournalPage, status = "Select a book" }, Cmd.none )

                ( "balance", Just bookId ) ->
                    ( { model
                        | page = BalanceSheetPage
                        , selectedLedgerRow = Nothing
                        , transactionEdit = Nothing
                        , editDirty = False
                        , editIdleTicks = 0
                        , loading = True
                        , status = "Loading balance sheet"
                      }
                    , loadBalance bookId model.reportDateInput
                    )

                ( "balance", Nothing ) ->
                    ( { model | page = BalanceSheetPage, status = "Select a book" }, Cmd.none )

                ( "trial-balance", Just bookId ) ->
                    ( { model
                        | page = TrialBalancePage
                        , selectedLedgerRow = Nothing
                        , transactionEdit = Nothing
                        , editDirty = False
                        , editIdleTicks = 0
                        , loading = True
                        , status = "Loading trial balance"
                      }
                    , loadTrialBalance bookId model.reportDateInput
                    )

                ( "trial-balance", Nothing ) ->
                    ( { model | page = TrialBalancePage, status = "Select a book" }, Cmd.none )

                ( "profit-loss", Just bookId ) ->
                    ( { model
                        | page = ProfitLossPage
                        , selectedLedgerRow = Nothing
                        , transactionEdit = Nothing
                        , editDirty = False
                        , editIdleTicks = 0
                        , loading = True
                        , status = "Loading profit and loss"
                      }
                    , loadProfitLoss
                        bookId
                        model.reportStartDateInput
                        model.reportEndDateInput
                    )

                ( "profit-loss", Nothing ) ->
                    ( { model | page = ProfitLossPage, status = "Select a book" }, Cmd.none )

                ( "cash-flow", Just bookId ) ->
                    ( { model
                        | page = CashFlowPage
                        , selectedLedgerRow = Nothing
                        , transactionEdit = Nothing
                        , editDirty = False
                        , editIdleTicks = 0
                        , loading = True
                        , status = "Loading cash flow"
                      }
                    , loadCashFlow
                        bookId
                        model.reportStartDateInput
                        model.reportEndDateInput
                    )

                ( "cash-flow", Nothing ) ->
                    ( { model | page = CashFlowPage, status = "Select a book" }, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        GotLedger result ->
            case result of
                Ok ledger ->
                    ( { model
                        | ledger = ledger
                        , selectedLedgerRow = Nothing
                        , transactionEdit = Nothing
                        , editDirty = False
                        , editIdleTicks = 0
                        , ledgerEdits = []
                        , expandedSplits = []
                        , loading = False
                        , status = "Ready"
                      }
                    , Cmd.none
                    )

                Err err ->
                    ( setError err model, Cmd.none )

        GotBalance result ->
            case result of
                Ok balance ->
                    ( { model
                        | balance = balance
                        , loading = False
                        , status = "Ready"
                      }
                    , Cmd.none
                    )

                Err err ->
                    ( setError err model, Cmd.none )

        GotTrialBalance result ->
            case result of
                Ok trialBalance ->
                    ( { model
                        | trialBalance = trialBalance
                        , loading = False
                        , status = "Ready"
                      }
                    , Cmd.none
                    )

                Err err ->
                    ( setError err model, Cmd.none )

        GotGeneralJournal result ->
            case result of
                Ok journal ->
                    ( { model
                        | journal = journal
                        , loading = False
                        , status = "Ready"
                      }
                    , Cmd.none
                    )

                Err err ->
                    ( setError err model, Cmd.none )

        UpdateBookId value ->
            ( { model | bookIdInput = value }, Cmd.none )

        UpdateBookName value ->
            ( { model | bookNameInput = value }, Cmd.none )

        UpdateBookAsset value ->
            ( { model | bookAssetInput = value }, Cmd.none )

        SubmitBook ->
            if String.trim model.bookIdInput == "" then
                ( { model | status = "Book id is required" }, Cmd.none )

            else if String.trim model.bookNameInput == "" then
                ( { model | status = "Book name is required" }, Cmd.none )

            else
                ( { model | loading = True, status = "Creating book" }
                , createBook model
                )

        CreatedBook result ->
            case result of
                Ok book ->
                    ( { model
                        | bookIdInput = ""
                        , bookNameInput = ""
                        , bookAssetInput = "GBP"
                        , selectedBook = Just book.id
                        , selectedAccount = Nothing
                        , ledger = []
                        , journal = []
                        , trialBalance = []
                        , selectedLedgerRow = Nothing
                        , transactionEdit = Nothing
                        , editDirty = False
                        , editIdleTicks = 0
                        , ledgerEdits = []
                        , expandedSplits = []
                        , appendOtherAccountInput = ""
                        , splitRows = [ emptySplitRow 1 ]
                        , nextSplitRowKey = 2
                        , page = LedgerPage
                        , loading = True
                        , status = "Book created"
                      }
                    , Cmd.batch [ loadBooks, loadAccounts book.id ]
                    )

                Err err ->
                    ( setError err model, Cmd.none )

        UpdateAccountId value ->
            ( { model | accountIdInput = value }, Cmd.none )

        UpdateAccountType value ->
            ( { model | accountTypeInput = value }, Cmd.none )

        UpdateAccountAsset value ->
            ( { model | accountAssetInput = value }, Cmd.none )

        UpdateAccountPretax value ->
            ( { model | accountPretaxInput = value }, Cmd.none )

        UpdateAccountOpeningBalance value ->
            ( { model | accountOpeningBalanceInput = value }, Cmd.none )

        UpdateAccountOpeningDate value ->
            ( { model | accountOpeningDateInput = value }, Cmd.none )

        SubmitAccount ->
            case ( model.selectedBook, parseFloat model.accountPretaxInput ) of
                ( Nothing, _ ) ->
                    ( { model | status = "Select a book first" }, Cmd.none )

                ( _, Nothing ) ->
                    ( { model | status = "Pretax must be numeric" }, Cmd.none )

                ( Just bookId, Just pretax ) ->
                    if String.trim model.accountIdInput == "" then
                        ( { model | status = "Account id is required" }, Cmd.none )

                    else
                        ( { model | loading = True, status = "Creating account" }
                        , createAccount bookId pretax model
                        )

        CreatedAccount result ->
            case result of
                Ok account ->
                    ( { model
                        | accountIdInput = ""
                        , accountPretaxInput = "1.0"
                        , accountOpeningBalanceInput = ""
                        , accountOpeningDateInput = ""
                        , selectedAccount = Just account.id
                        , appendOtherAccountInput = ""
                        , page = LedgerPage
                        , selectedLedgerRow = Nothing
                        , transactionEdit = Nothing
                        , editDirty = False
                        , editIdleTicks = 0
                        , ledgerEdits = []
                        , expandedSplits = []
                        , loading = True
                        , status = "Account created"
                      }
                    , Cmd.batch
                        [ loadAccounts account.bookId
                        , loadLedger account.bookId account.id
                        ]
                    )

                Err err ->
                    ( setError err model, Cmd.none )

        UpdateReportDate value ->
            ( { model | reportDateInput = value }, Cmd.none )

        UpdateReportStartDate value ->
            ( { model | reportStartDateInput = value }, Cmd.none )

        UpdateReportEndDate value ->
            ( { model | reportEndDateInput = value }, Cmd.none )

        RefreshReport ->
            refreshCurrentReport model

        UpdateAppendDate value ->
            ( { model | appendDateInput = value }, Cmd.none )

        UpdateAppendMemo value ->
            ( { model | appendMemoInput = value }, Cmd.none )

        UpdateAppendOtherAccount value ->
            ( { model
                | appendOtherAccountInput = value
                , appendSplitInput = String.trim value == splitTransferLabel
              }
            , Cmd.none )

        UpdateAppendDebit value ->
            ( { model | appendDebitInput = value }, Cmd.none )

        UpdateAppendCredit value ->
            ( { model | appendCreditInput = value }, Cmd.none )

        UpdateAppendResolved value ->
            ( { model | appendResolvedInput = value }, Cmd.none )

        ToggleAppendSplit ->
            let
                splitMode =
                    not model.appendSplitInput
            in
            ( { model
                | appendSplitInput = splitMode
                , status =
                    if splitMode then
                        "Split entry"

                    else
                        "Single transfer"
              }
            , Cmd.none
            )

        AddSplitRow ->
            ( { model
                | splitRows = model.splitRows ++ [ emptySplitRow model.nextSplitRowKey ]
                , nextSplitRowKey = model.nextSplitRowKey + 1
              }
            , Cmd.none
            )

        RemoveSplitRow key ->
            let
                remaining =
                    List.filter (\row -> row.key /= key) model.splitRows
            in
            if List.isEmpty remaining then
                ( { model
                    | splitRows = [ emptySplitRow model.nextSplitRowKey ]
                    , nextSplitRowKey = model.nextSplitRowKey + 1
                  }
                , Cmd.none
                )

            else
                ( { model | splitRows = remaining }, Cmd.none )

        UpdateLedgerDate xid account value ->
            ( { model | ledgerEdits = upsertLedgerEdit xid account (\edit -> { edit | date = value }) model }
            , Cmd.none
            )

        UpdateLedgerDescription xid account value ->
            ( { model | ledgerEdits = upsertLedgerEdit xid account (\edit -> { edit | description = value }) model }
            , Cmd.none
            )

        UpdateSplitAccount key value ->
            ( { model | splitRows = updateSplitRow key (\row -> { row | account = value }) model.splitRows }
            , Cmd.none
            )

        UpdateSplitMemo key value ->
            ( { model | splitRows = updateSplitRow key (\row -> { row | memo = value }) model.splitRows }
            , Cmd.none
            )

        UpdateSplitDebit key value ->
            ( { model | splitRows = updateSplitRow key (\row -> { row | debit = value }) model.splitRows }
            , Cmd.none
            )

        UpdateSplitCredit key value ->
            ( { model | splitRows = updateSplitRow key (\row -> { row | credit = value }) model.splitRows }
            , Cmd.none
            )

        ToggleSplit xid ->
            if List.member xid model.expandedSplits then
                ( { model
                    | expandedSplits =
                        List.filter (\expanded -> expanded /= xid) model.expandedSplits
                  }
                , Cmd.none
                )

            else
                ( { model | expandedSplits = xid :: model.expandedSplits }
                , Cmd.none
                )

        SelectLedgerRow selection ->
            selectLedgerRow selection model

        UpdateTransactionDate value ->
            ( updateTransactionEdit (\edit -> { edit | date = value }) model, Cmd.none )

        UpdateTransactionMemo key value ->
            ( updateTransactionEditLine key (\line -> { line | memo = value }) model
            , Cmd.none
            )

        UpdateTransactionAccount key value ->
            ( updateTransactionEditLine key (\line -> { line | account = value }) model
            , Cmd.none
            )

        UpdateTransactionDebit key value ->
            ( updateTransactionEditLine key (\line -> { line | debit = value, credit = "" }) model
            , Cmd.none
            )

        UpdateTransactionCredit key value ->
            ( updateTransactionEditLine key (\line -> { line | credit = value, debit = "" }) model
            , Cmd.none
            )

        AddTransactionSplitLine ->
            ( addTransactionSplitLine model, Cmd.none )

        RemoveTransactionLine key ->
            ( updateTransactionEdit
                (\edit ->
                    { edit
                        | split = True
                        , lines = List.filter (\line -> line.primary || line.key /= key) edit.lines
                    }
                )
                model
            , Cmd.none
            )

        SaveSelectedTransaction ->
            saveSelectedTransaction model

        AutoSaveTick _ ->
            autoSaveTransaction model

        SavedTransaction xid result ->
            case result of
                Ok _ ->
                    ( markSavedTransaction xid model, Cmd.none )

                Err err ->
                    ( setError err model, Cmd.none )

        SubmitLedgerLine xid account ->
            submitLedgerLine xid account model

        UpdatedLedgerLine result ->
            case result of
                Ok _ ->
                    refreshLedgerAfterLineUpdate { model | ledgerEdits = [] }

                Err err ->
                    ( setError err model, Cmd.none )

        StartLedgerColumnResize column startX ->
            ( { model
                | resizingLedgerColumn =
                    Just
                        { column = column
                        , startX = startX
                        , startWidth = ledgerColumnWidth column model
                        }
              }
            , Cmd.none
            )

        DragLedgerColumnResize currentX ->
            case model.resizingLedgerColumn of
                Just resize ->
                    let
                        width =
                            max
                                (ledgerColumnMinWidth resize.column)
                                (resize.startWidth + currentX - resize.startX)
                    in
                    ( { model
                        | ledgerColumnWidths =
                            setLedgerColumnWidth resize.column width model.ledgerColumnWidths
                      }
                    , Cmd.none
                    )

                Nothing ->
                    ( model, Cmd.none )

        StopLedgerColumnResize ->
            ( { model | resizingLedgerColumn = Nothing }, Cmd.none )

        AppendTransaction ->
            appendTransaction model

        CreatedTransactionResponse result ->
            case result of
                Ok created ->
                    ( { model
                        | appendMemoInput = ""
                        , appendDebitInput = ""
                        , appendCreditInput = ""
                        , appendOtherAccountInput = ""
                        , appendSplitInput = False
                        , splitRows = [ emptySplitRow 1 ]
                        , nextSplitRowKey = 2
                        , loading = True
                        , status = "Transaction " ++ String.fromInt created.xid ++ " created"
                      }
                    , Cmd.batch
                        [ loadBalance created.bookId model.reportDateInput
                        , loadSelectedLedger created.bookId model
                        ]
                    )

                Err err ->
                    ( setError err model, Cmd.none )

        RefreshAll ->
            case model.selectedBook of
                Just bookId ->
                    ( { model | loading = True, status = "Refreshing" }
                    , Cmd.batch [ loadBooks, loadAccounts bookId ]
                    )

                Nothing ->
                    ( { model | loading = True, status = "Refreshing" }, loadBooks )


selectedBookAfterLoad : Maybe String -> List Book -> Maybe String
selectedBookAfterLoad current books =
    case current of
        Just bookId ->
            if List.any (\book -> book.id == bookId) books then
                Just bookId

            else
                books |> List.head |> Maybe.map .id

        Nothing ->
            books |> List.head |> Maybe.map .id


selectedAccountAfterLoad : Maybe String -> List Account -> Maybe String
selectedAccountAfterLoad current accounts =
    case current of
        Just accountId ->
            if List.any (\account -> account.id == accountId) accounts then
                Just accountId

            else
                accounts |> List.head |> Maybe.map .id

        Nothing ->
            accounts |> List.head |> Maybe.map .id


selectedLedgerAccount : Model -> String
selectedLedgerAccount model =
    case model.selectedAccount of
        Just accountId ->
            if List.any (\account -> account.id == accountId) model.accounts then
                accountId

            else
                model.accounts |> List.head |> Maybe.map .id |> Maybe.withDefault ""

        Nothing ->
            model.accounts |> List.head |> Maybe.map .id |> Maybe.withDefault ""


updateSplitRow : Int -> (SplitLineInput -> SplitLineInput) -> List SplitLineInput -> List SplitLineInput
updateSplitRow key updateRow rows =
    List.map
        (\row ->
            if row.key == key then
                updateRow row

            else
                row
        )
        rows


selectLedgerRow : LedgerRowSelection -> Model -> ( Model, Cmd Msg )
selectLedgerRow selection model =
    if model.selectedLedgerRow == Just selection then
        ( model, Cmd.none )

    else
        case model.selectedLedgerRow of
            Just currentSelection ->
                if currentSelection.xid == selection.xid then
                    ( { model | selectedLedgerRow = Just selection }, Cmd.none )

                else
                    leaveTransactionFor selection model

            Nothing ->
                leaveTransactionFor selection model


leaveTransactionFor : LedgerRowSelection -> Model -> ( Model, Cmd Msg )
leaveTransactionFor selection model =
    case model.transactionEdit of
        Just edit ->
            case validateTransactionEdit edit of
                Err message ->
                    let
                        alert =
                            "Cannot leave transaction: " ++ message
                    in
                    ( { model | status = alert }, alertUser alert )

                Ok _ ->
                    if model.editDirty then
                        ( activateLedgerSelection selection
                            { model | status = "Saving transaction" }
                        , saveTransactionEdit model edit
                        )

                    else
                        ( activateLedgerSelection selection model, Cmd.none )

        Nothing ->
            ( activateLedgerSelection selection model, Cmd.none )


activateLedgerSelection : LedgerRowSelection -> Model -> Model
activateLedgerSelection selection model =
    { model
        | selectedLedgerRow = Just selection
        , transactionEdit = transactionEditFromSelection selection model
        , editDirty = False
        , editIdleTicks = 0
        , expandedSplits = [ selection.xid ]
    }


transactionEditFromSelection : LedgerRowSelection -> Model -> Maybe TransactionEdit
transactionEditFromSelection selection model =
    transactionEntry selection model.ledger
        |> Maybe.map
            (\entry ->
                let
                    lines =
                        transactionEditLines selection entry
                in
                { xid = selection.xid
                , date = entry.date
                , resolved = entry.reconciled
                , split = entry.split
                , lines = lines
                , nextKey = List.length lines + 1
                }
            )


transactionEntry : LedgerRowSelection -> List LedgerEntry -> Maybe LedgerEntry
transactionEntry selection ledger =
    let
        selectedLine =
            ledger
                |> List.filter
                    (\entry ->
                        entry.xid == selection.xid
                            && (entry.account == Just selection.account
                                    || List.any
                                        (\line -> line.account == selection.account)
                                        entry.splitLines
                               )
                    )
                |> List.head
    in
    case selectedLine of
        Just entry ->
            Just entry

        Nothing ->
            ledger
                |> List.filter (\entry -> entry.xid == selection.xid)
                |> List.head


transactionEditLines : LedgerRowSelection -> LedgerEntry -> List TransactionEditLine
transactionEditLines selection entry =
    let
        rawLines =
            if entry.split then
                List.map
                    (\line ->
                        { account = line.account
                        , memo = Maybe.withDefault "" line.description
                        , amount = line.amount
                        }
                    )
                    entry.splitLines

            else
                [ { account = Maybe.withDefault selection.account entry.account
                  , memo = Maybe.withDefault "" entry.description
                  , amount = entry.amount
                  }
                , { account = Maybe.withDefault "" entry.transfer
                  , memo = Maybe.withDefault "" entry.description
                  , amount = negate entry.amount
                  }
                ]

        primaryAccount =
            selection.account
    in
    rawLines
        |> moveAccountFirst primaryAccount
        |> List.indexedMap
            (\index line ->
                transactionLineToEdit
                    (index + 1)
                    (line.account == primaryAccount)
                    line
            )


moveAccountFirst : String -> List { a | account : String } -> List { a | account : String }
moveAccountFirst account lines =
    let
        matching =
            List.filter (\line -> line.account == account) lines

        rest =
            List.filter (\line -> line.account /= account) lines
    in
    matching ++ rest


transactionLineToEdit :
    Int
    -> Bool
    -> { a | account : String, memo : String, amount : Float }
    -> TransactionEditLine
transactionLineToEdit key primary line =
    { key = key
    , account = line.account
    , memo = line.memo
    , debit =
        if line.amount > 0 then
            money line.amount

        else
            ""
    , credit =
        if line.amount < 0 then
            money (negate line.amount)

        else
            ""
    , primary = primary
    }


updateTransactionEdit : (TransactionEdit -> TransactionEdit) -> Model -> Model
updateTransactionEdit updateEdit model =
    { model
        | transactionEdit = Maybe.map updateEdit model.transactionEdit
        , editDirty = True
        , editIdleTicks = 0
    }


updateTransactionEditLine :
    Int
    -> (TransactionEditLine -> TransactionEditLine)
    -> Model
    -> Model
updateTransactionEditLine key updateLine model =
    updateTransactionEdit
        (\edit ->
            let
                updatedLines =
                    List.map
                        (\line ->
                            if line.key == key then
                                updateLine line

                            else
                                line
                        )
                        edit.lines
            in
            if edit.split then
                { edit | lines = updatedLines }

            else
                rebalanceSimpleEdit { edit | lines = updatedLines }
        )
        model


rebalanceSimpleEdit : TransactionEdit -> TransactionEdit
rebalanceSimpleEdit edit =
    case edit.lines of
        primary :: other :: rest ->
            case editLineAmount primary of
                Ok amount ->
                    { edit
                        | lines =
                            primary
                                :: { other
                                    | debit =
                                        if amount < 0 then
                                            money (negate amount)

                                        else
                                            ""
                                    , credit =
                                        if amount > 0 then
                                            money amount

                                        else
                                            ""
                                  }
                                :: rest
                    }

                Err _ ->
                    edit

        _ ->
            edit


addTransactionSplitLine : Model -> Model
addTransactionSplitLine model =
    updateTransactionEdit
        (\edit ->
            { edit
                | split = True
                , lines =
                    edit.lines
                        ++ [ { key = edit.nextKey
                             , account = ""
                             , memo = ""
                             , debit = ""
                             , credit = ""
                             , primary = False
                             }
                           ]
                , nextKey = edit.nextKey + 1
            }
        )
        model


saveSelectedTransaction : Model -> ( Model, Cmd Msg )
saveSelectedTransaction model =
    case model.transactionEdit of
        Nothing ->
            ( model, Cmd.none )

        Just edit ->
            case validateTransactionEdit edit of
                Ok _ ->
                    ( { model | loading = True, status = "Saving transaction" }
                    , saveTransactionEdit model edit
                    )

                Err message ->
                    let
                        alert =
                            "Cannot save transaction: " ++ message
                    in
                    ( { model | status = alert }, alertUser alert )


autoSaveTransaction : Model -> ( Model, Cmd Msg )
autoSaveTransaction model =
    case model.transactionEdit of
        Just edit ->
            case validateTransactionEdit edit of
                Ok _ ->
                    if model.editIdleTicks >= 2 then
                        ( { model | loading = True, status = "Autosaving transaction" }
                        , saveTransactionEdit model edit
                        )

                    else
                        ( { model | editIdleTicks = model.editIdleTicks + 1 }, Cmd.none )

                Err _ ->
                    ( { model | editIdleTicks = 0 }, Cmd.none )

        Nothing ->
            ( { model | editDirty = False, editIdleTicks = 0 }, Cmd.none )


saveTransactionEdit : Model -> TransactionEdit -> Cmd Msg
saveTransactionEdit model edit =
    case model.selectedBook of
        Just bookId ->
            updateTransaction bookId edit

        Nothing ->
            Cmd.none


markSavedTransaction : Int -> Model -> Model
markSavedTransaction xid model =
    case model.transactionEdit of
        Just edit ->
            if edit.xid == xid then
                { model
                    | editDirty = False
                    , editIdleTicks = 0
                    , loading = False
                    , status = "Transaction saved"
                }

            else
                { model | loading = False, status = "Transaction saved" }

        Nothing ->
            { model | loading = False, status = "Transaction saved" }


validateTransactionEdit : TransactionEdit -> Result String (List TransactionLineDraft)
validateTransactionEdit edit =
    if String.trim edit.date == "" then
        Err "date is required"

    else
        parseTransactionEditLines edit.lines
            |> Result.andThen
                (\lines ->
                    if List.length lines < 2 then
                        Err "at least two lines are required"

                    else if hasDuplicate (List.map .account lines) then
                        Err "each line must use a different account"

                    else if lineTotalCents lines /= 0 then
                        Err "transaction is not balanced"

                    else
                        Ok lines
                )


parseTransactionEditLines : List TransactionEditLine -> Result String (List TransactionLineDraft)
parseTransactionEditLines lines =
    case lines of
        [] ->
            Ok []

        line :: rest ->
            editLineDraft line
                |> Result.andThen
                    (\draft ->
                        parseTransactionEditLines rest
                            |> Result.map (\drafts -> draft :: drafts)
                    )


editLineDraft : TransactionEditLine -> Result String TransactionLineDraft
editLineDraft line =
    let
        account =
            String.trim line.account
    in
    if account == "" then
        Err "account is required"

    else
        editLineAmount line
            |> Result.map
                (\amount ->
                    { account = account
                    , amount = amount
                    , memo = String.trim line.memo
                    }
                )


editLineAmount : TransactionEditLine -> Result String Float
editLineAmount line =
    case ( blankToNothing line.debit, blankToNothing line.credit ) of
        ( Nothing, Nothing ) ->
            Err "each line needs a deposit or withdrawal"

        ( Just _, Just _ ) ->
            Err "use either deposit or withdrawal on each line"

        ( Just raw, Nothing ) ->
            parsePositiveAmount "Deposit" raw

        ( Nothing, Just raw ) ->
            parsePositiveAmount "Withdrawal" raw
                |> Result.map negate


refreshCurrentReport : Model -> ( Model, Cmd Msg )
refreshCurrentReport model =
    case ( model.page, model.selectedBook, model.selectedAccount ) of
        ( LedgerPage, Just bookId, _ ) ->
            let
                accountId =
                    selectedLedgerAccount model
            in
            if accountId == "" then
                ( { model | status = "Create or select an account" }, Cmd.none )

            else
                ( { model | loading = True, status = "Loading ledger" }
                , loadLedger bookId accountId
                )

        ( GeneralJournalPage, Just bookId, _ ) ->
            ( { model | loading = True, status = "Loading general journal" }
            , loadGeneralJournal bookId
            )

        ( BalanceSheetPage, Just bookId, _ ) ->
            ( { model | loading = True, status = "Loading balance sheet" }
            , loadBalance bookId model.reportDateInput
            )

        ( TrialBalancePage, Just bookId, _ ) ->
            ( { model | loading = True, status = "Loading trial balance" }
            , loadTrialBalance bookId model.reportDateInput
            )

        ( ProfitLossPage, Just bookId, _ ) ->
            ( { model | loading = True, status = "Loading profit and loss" }
            , loadProfitLoss
                bookId
                model.reportStartDateInput
                model.reportEndDateInput
            )

        ( CashFlowPage, Just bookId, _ ) ->
            ( { model | loading = True, status = "Loading cash flow" }
            , loadCashFlow
                bookId
                model.reportStartDateInput
                model.reportEndDateInput
            )

        _ ->
            ( model, Cmd.none )


refreshLedgerAfterLineUpdate : Model -> ( Model, Cmd Msg )
refreshLedgerAfterLineUpdate model =
    case model.selectedBook of
        Just bookId ->
            let
                accountId =
                    selectedLedgerAccount model
            in
            if accountId == "" then
                ( { model | loading = False, status = "Line updated" }, Cmd.none )

            else
                ( { model | loading = True, status = "Line updated" }
                , loadLedger bookId accountId
                )

        _ ->
            ( { model | loading = False, status = "Line updated" }, Cmd.none )


submitLedgerLine : Int -> String -> Model -> ( Model, Cmd Msg )
submitLedgerLine xid account model =
    case model.selectedBook of
        Nothing ->
            ( { model | status = "Select a book first" }, Cmd.none )

        Just bookId ->
            let
                edit =
                    ledgerLineEditValue xid account model
            in
            if String.trim edit.date == "" then
                ( { model | status = "Date is required" }, Cmd.none )

            else
                ( { model | loading = True, status = "Updating line" }
                , updateLedgerLine bookId edit
                )


upsertLedgerEdit : Int -> String -> (LedgerLineEdit -> LedgerLineEdit) -> Model -> List LedgerLineEdit
upsertLedgerEdit xid account editLine model =
    let
        edited =
            editLine (ledgerLineEditValue xid account model)

        matches line =
            line.xid == xid && line.account == account
    in
    if List.any matches model.ledgerEdits then
        List.map
            (\line ->
                if matches line then
                    edited

                else
                    line
            )
            model.ledgerEdits

    else
        edited :: model.ledgerEdits


ledgerLineEditValue : Int -> String -> Model -> LedgerLineEdit
ledgerLineEditValue xid account model =
    existingLedgerEdit xid account model
        |> Maybe.withDefault (baseLedgerLineEdit xid account model)


existingLedgerEdit : Int -> String -> Model -> Maybe LedgerLineEdit
existingLedgerEdit xid account model =
    model.ledgerEdits
        |> List.filter (\line -> line.xid == xid && line.account == account)
        |> List.head


baseLedgerLineEdit : Int -> String -> Model -> LedgerLineEdit
baseLedgerLineEdit xid account model =
    { xid = xid
    , account = account
    , date = ledgerLineBaseDate xid model
    , description = ledgerLineBaseDescription xid account model
    }


ledgerLineBaseDate : Int -> Model -> String
ledgerLineBaseDate xid model =
    model.ledger
        |> List.filter (\entry -> entry.xid == xid)
        |> List.head
        |> Maybe.map .date
        |> Maybe.withDefault ""


ledgerLineBaseDescription : Int -> String -> Model -> String
ledgerLineBaseDescription xid account model =
    case ledgerDirectEntry xid account model.ledger of
        Just entry ->
            Maybe.withDefault "" entry.description

        Nothing ->
            ledgerSplitLine xid account model.ledger
                |> Maybe.andThen .description
                |> Maybe.withDefault ""


ledgerDirectEntry : Int -> String -> List LedgerEntry -> Maybe LedgerEntry
ledgerDirectEntry xid account ledger =
    ledger
        |> List.filter
            (\entry ->
                entry.xid == xid && entry.account == Just account
            )
        |> List.head


ledgerSplitLine : Int -> String -> List LedgerEntry -> Maybe LedgerSplitLine
ledgerSplitLine xid account ledger =
    case ledger of
        [] ->
            Nothing

        entry :: rest ->
            if entry.xid == xid then
                case List.filter (\line -> line.account == account) entry.splitLines |> List.head of
                    Just line ->
                        Just line

                    Nothing ->
                        ledgerSplitLine xid account rest

            else
                ledgerSplitLine xid account rest


appendTransaction : Model -> ( Model, Cmd Msg )
appendTransaction model =
    case model.selectedBook of
        Nothing ->
            ( { model | status = "Select a book first" }, Cmd.none )

        Just bookId ->
            let
                accountId =
                    selectedLedgerAccount model
            in
            if accountId == "" then
                ( { model | status = "Select an account first" }, Cmd.none )

            else
                appendAccountTransaction bookId accountId model


loadSelectedLedger : String -> Model -> Cmd Msg
loadSelectedLedger bookId model =
    let
        accountId =
            selectedLedgerAccount model
    in
    if accountId == "" then
        Cmd.none

    else
        loadLedger bookId accountId


appendAccountTransaction : String -> String -> Model -> ( Model, Cmd Msg )
appendAccountTransaction bookId accountId model =
    if String.trim model.appendDateInput == "" then
        ( { model | status = "Date is required" }, Cmd.none )

    else
        case appendLines accountId model of
            Ok lines ->
                ( { model | loading = True, status = "Appending transaction" }
                , createTransaction bookId lines model
                )

            Err message ->
                ( { model | status = message }, Cmd.none )
appendLines : String -> Model -> Result String (List TransactionLineDraft)
appendLines currentAccount model =
    primaryAppendLine currentAccount model
        |> Result.andThen
            (\primary ->
                if appendUsesSplit model then
                    splitAppendLines primary model

                else
                    simpleAppendLines primary model
            )


appendUsesSplit : Model -> Bool
appendUsesSplit model =
    model.appendSplitInput
        || String.trim model.appendOtherAccountInput == splitTransferLabel


primaryAppendLine : String -> Model -> Result String TransactionLineDraft
primaryAppendLine currentAccount model =
    let
        debit =
            blankToNothing model.appendDebitInput

        credit =
            blankToNothing model.appendCreditInput

        memo =
            ""
    in
    case ( debit, credit ) of
        ( Nothing, Nothing ) ->
            Err "Enter a debit or credit"

        ( Just _, Just _ ) ->
            Err "Enter either a debit or credit, not both"

        ( Just raw, Nothing ) ->
            raw
                |> parsePositiveAmount "Debit"
                |> Result.map
                    (\amount -> { account = currentAccount, amount = amount, memo = memo })

        ( Nothing, Just raw ) ->
            raw
                |> parsePositiveAmount "Credit"
                |> Result.map
                    (\amount ->
                        { account = currentAccount, amount = negate amount, memo = memo }
                    )


simpleAppendLines : TransactionLineDraft -> Model -> Result String (List TransactionLineDraft)
simpleAppendLines primary model =
    let
        otherAccount =
            String.trim model.appendOtherAccountInput
    in
    if otherAccount == "" then
        Err "Transfer account is required"

    else if otherAccount == primary.account then
        Err "Transfer account must differ from the ledger account"

    else
        Ok
            [ primary
            , { account = otherAccount
              , amount = negate primary.amount
              , memo = primary.memo
              }
            ]


splitAppendLines : TransactionLineDraft -> Model -> Result String (List TransactionLineDraft)
splitAppendLines primary model =
    let
        activeRows =
            List.filter (not << splitRowIsBlank) model.splitRows
    in
    if List.isEmpty activeRows then
        Err "Add at least one split line"

    else
        parseSplitRows activeRows
            |> Result.andThen
                (\splitLines ->
                    validateSplitAccounts primary splitLines
                        |> Result.andThen
                            (\_ ->
                                let
                                    lines =
                                        primary :: splitLines
                                in
                                if lineTotalCents lines == 0 then
                                    Ok lines

                                else
                                    Err "Split lines must balance the ledger amount"
                            )
                )


validateSplitAccounts : TransactionLineDraft -> List TransactionLineDraft -> Result String ()
validateSplitAccounts primary splitLines =
    let
        accounts =
            List.map .account splitLines
    in
    if List.member primary.account accounts then
        Err "Split lines cannot use the ledger account"

    else if hasDuplicate accounts then
        Err "Each split line must use a different account"

    else
        Ok ()


hasDuplicate : List String -> Bool
hasDuplicate values =
    case values of
        [] ->
            False

        value :: rest ->
            List.member value rest || hasDuplicate rest


parseSplitRows : List SplitLineInput -> Result String (List TransactionLineDraft)
parseSplitRows rows =
    case rows of
        [] ->
            Ok []

        row :: rest ->
            splitRowLine row
                |> Result.andThen
                    (\line ->
                        parseSplitRows rest
                            |> Result.map (\lines -> line :: lines)
                    )


splitRowLine : SplitLineInput -> Result String TransactionLineDraft
splitRowLine row =
    let
        account =
            String.trim row.account

        debit =
            blankToNothing row.debit

        credit =
            blankToNothing row.credit

        memo =
            String.trim row.memo
    in
    if account == "" then
        Err "Split line account is required"

    else
        case ( debit, credit ) of
            ( Nothing, Nothing ) ->
                Err "Split line needs a debit or credit"

            ( Just _, Just _ ) ->
                Err "Split line can use debit or credit, not both"

            ( Just raw, Nothing ) ->
                raw
                    |> parsePositiveAmount "Split debit"
                    |> Result.map
                        (\amount -> { account = account, amount = amount, memo = memo })

            ( Nothing, Just raw ) ->
                raw
                    |> parsePositiveAmount "Split credit"
                    |> Result.map
                        (\amount ->
                            { account = account, amount = negate amount, memo = memo }
                        )


splitRowIsBlank : SplitLineInput -> Bool
splitRowIsBlank row =
    String.trim row.account == ""
        && String.trim row.memo == ""
        && String.trim row.debit == ""
        && String.trim row.credit == ""


parsePositiveAmount : String -> String -> Result String Float
parsePositiveAmount label raw =
    case String.toFloat (String.trim raw) of
        Just amount ->
            if amount > 0 then
                Ok amount

            else
                Err (label ++ " must be greater than zero")

        Nothing ->
            Err (label ++ " is not numeric")


lineTotalCents : List TransactionLineDraft -> Int
lineTotalCents lines =
    lines
        |> List.map (\line -> round (line.amount * 100))
        |> List.sum


view : Model -> Html Msg
view model =
    Html.div [ Attr.class "app-shell" ]
        [ viewTopBar model
        , Html.main_ [ Attr.class "page-shell" ] [ viewPage model ]
        ]


viewTopBar : Model -> Html Msg
viewTopBar model =
    Html.header [ Attr.class "topbar" ]
        (List.concat
            [ [ Html.div [ Attr.class "brand" ]
                    [ Html.h1 [] [ Html.text "Plutus" ] ]
              , navSelect "Book"
                    (Maybe.withDefault "" model.selectedBook)
                    SelectBookMenu
                    (List.map (\book -> ( book.id, book.name )) model.books
                        ++ [ ( addBookValue, "Add New Book..." ) ]
                    )
              , navSelect "Reports"
                    (reportValue model.page)
                    SelectReport
                [ ( "ledger", "Ledger" )
                , ( "general-journal", "General Journal" )
                , ( "balance", "Balance Sheet" )
                , ( "trial-balance", "Trial Balance" )
                , ( "profit-loss", "Profit & Loss" )
                , ( "cash-flow", "Cash Flow" )
                ]
              ]
            , if reportUsesAccount model.page then
                [ navSelect "Account"
                    (selectedLedgerAccount model)
                    SelectAccountMenu
                    (accountMenuOptions model.accounts)
                ]

              else
                []
            , [ Html.div [ Attr.class "future-actions" ]
                    [ Html.button [ Attr.type_ "button", Attr.disabled True ] [ Html.text "More" ] ]
              , Html.div [ Attr.class "status-line" ]
                    [ Html.span [ Attr.classList [ ( "busy", model.loading ) ] ]
                        [ Html.text model.status ]
                    , Html.button [ Attr.type_ "button", Events.onClick RefreshAll ]
                        [ Html.text "Refresh" ]
                    ]
              ]
            ]
        )


navSelect : String -> String -> (String -> Msg) -> List ( String, String ) -> Html Msg
navSelect labelText current toMsg options =
    Html.label [ Attr.class "nav-field" ]
        [ Html.span [] [ Html.text labelText ]
        , Html.select
            [ Attr.value current
            , Events.onInput toMsg
            ]
            (List.map
                (\( value, label ) ->
                    Html.option [ Attr.value value ] [ Html.text label ]
                )
                options
            )
        ]


accountMenuOptions : List Account -> List ( String, String )
accountMenuOptions accounts =
    List.map (\account -> ( account.id, account.id )) accounts
        ++ [ ( addAccountValue, "Add New Account..." ) ]


reportUsesAccount : Page -> Bool
reportUsesAccount page =
    case page of
        LedgerPage ->
            True

        _ ->
            False


viewPage : Model -> Html Msg
viewPage model =
    case model.page of
        LedgerPage ->
            viewLedgerPage model

        GeneralJournalPage ->
            viewGeneralJournalPage model

        BalanceSheetPage ->
            viewBalancePage model

        TrialBalancePage ->
            viewTrialBalancePage model

        ProfitLossPage ->
            viewProfitLossPage model

        CashFlowPage ->
            viewCashFlowPage model

        AddBookPage ->
            viewAddBookPage model

        AddAccountPage ->
            viewAddAccountPage model


viewLedgerPage : Model -> Html Msg
viewLedgerPage model =
    let
        transferAccounts =
            transferAccountChoices model
    in
    Html.section [ Attr.class "panel ledger-panel" ]
        [ sectionHeader
            ("Ledger"
                ++ (": " ++ selectedAccountTitle model)
            )
        , accountChoicesDatalist
            transferChoicesListId
            (splitTransferLabel :: List.map .id transferAccounts)
        , accountChoicesDatalist
            splitAccountChoicesListId
            (List.map .id transferAccounts)
        , accountChoicesDatalist
            editAccountChoicesListId
            (editAccountChoices model)
        , Html.table
            [ Attr.classList
                [ ( "ledger-table", True )
                , ( "ledger-register", True )
                , ( "ledger-table-resizing", model.resizingLedgerColumn /= Nothing )
                ]
            , Attr.style "width" (px (ledgerTableWidth model))
            ]
            [ Html.colgroup [] (List.map (viewLedgerCol model) ledgerColumns)
            , Html.thead []
                [ viewLedgerHeader model ]
            , Html.tbody []
                (model.ledger
                    |> List.indexedMap (viewLedgerEntry model False)
                    |> List.concat
                )
            , Html.tfoot [] (viewAppendRows model)
            ]
        ]


transferAccountChoices : Model -> List Account
transferAccountChoices model =
    let
        currentAccount =
            selectedLedgerAccount model
    in
    List.filter (\account -> account.id /= currentAccount) model.accounts


editAccountChoices : Model -> List String
editAccountChoices model =
    let
        currentAccount =
            model.transactionEdit
                |> Maybe.andThen primaryEditLine
                |> Maybe.map .account
    in
    model.accounts
        |> List.map .id
        |> List.filter
            (\account ->
                case currentAccount of
                    Just selectedAccount ->
                        account /= selectedAccount

                    Nothing ->
                        True
            )


selectedAccountTitle : Model -> String
selectedAccountTitle model =
    let
        accountId =
            selectedLedgerAccount model
    in
    if accountId == "" then
        "No account"

    else
        accountId


ledgerColumns : List LedgerColumn
ledgerColumns =
    [ { id = LedgerDateColumn, label = "Date", className = "ledger-date", defaultWidth = 136, minWidth = 112 }
    , { id = LedgerXidColumn, label = "XID", className = "ledger-xid", defaultWidth = 88, minWidth = 56 }
    , { id = LedgerDescriptionColumn, label = "Description", className = "ledger-description", defaultWidth = 300, minWidth = 160 }
    , { id = LedgerTransferColumn, label = "Transfer", className = "ledger-transfer", defaultWidth = 272, minWidth = 160 }
    , { id = LedgerReconciledColumn, label = "R", className = "ledger-reconciled", defaultWidth = 52, minWidth = 44 }
    , { id = LedgerDepositColumn, label = "Deposit", className = "ledger-deposit number", defaultWidth = 118, minWidth = 88 }
    , { id = LedgerWithdrawalColumn, label = "Withdrawal", className = "ledger-withdrawal number", defaultWidth = 118, minWidth = 96 }
    , { id = LedgerBalanceColumn, label = "Balance", className = "ledger-balance number", defaultWidth = 118, minWidth = 88 }
    ]


viewLedgerHeader : Model -> Html Msg
viewLedgerHeader model =
    Html.tr []
        (List.map
            (\column ->
                Html.th
                    [ Attr.class (column.className ++ " resizable-header")
                    , Attr.style "width" (px (ledgerColumnWidth column.id model))
                    ]
                    [ Html.span [ Attr.class "column-label" ] [ Html.text column.label ]
                    , Html.button
                        [ Attr.type_ "button"
                        , Attr.class "column-resize-handle"
                        , Attr.attribute "aria-label" ("Resize " ++ column.label)
                        , Attr.title ("Resize " ++ column.label)
                        , columnResizeMouseDown column.id
                        ]
                        []
                    ]
            )
            ledgerColumns
        )


viewLedgerCol : Model -> LedgerColumn -> Html Msg
viewLedgerCol model column =
    Html.col
        [ Attr.style "width" (px (ledgerColumnWidth column.id model)) ]
        []


columnResizeMouseDown : LedgerColumnId -> Html.Attribute Msg
columnResizeMouseDown column =
    Events.preventDefaultOn "mousedown"
        (Decode.map
            (\startX -> ( StartLedgerColumnResize column startX, True ))
            (Decode.field "clientX" Decode.float)
        )


ledgerTableWidth : Model -> Float
ledgerTableWidth model =
    ledgerColumns
        |> List.map (\column -> ledgerColumnWidth column.id model)
        |> List.sum


ledgerColumnWidth : LedgerColumnId -> Model -> Float
ledgerColumnWidth column model =
    model.ledgerColumnWidths
        |> List.filter (\stored -> stored.column == column)
        |> List.head
        |> Maybe.map .width
        |> Maybe.withDefault (ledgerColumnDefaultWidth column)


ledgerColumnDefaultWidth : LedgerColumnId -> Float
ledgerColumnDefaultWidth column =
    ledgerColumns
        |> List.filter (\candidate -> candidate.id == column)
        |> List.head
        |> Maybe.map .defaultWidth
        |> Maybe.withDefault 120


ledgerColumnMinWidth : LedgerColumnId -> Float
ledgerColumnMinWidth column =
    ledgerColumns
        |> List.filter (\candidate -> candidate.id == column)
        |> List.head
        |> Maybe.map .minWidth
        |> Maybe.withDefault 72


setLedgerColumnWidth : LedgerColumnId -> Float -> List LedgerColumnWidth -> List LedgerColumnWidth
setLedgerColumnWidth column width widths =
    let
        storedWidth =
            { column = column, width = width }
    in
    if List.any (\stored -> stored.column == column) widths then
        List.map
            (\stored ->
                if stored.column == column then
                    storedWidth

                else
                    stored
            )
            widths

    else
        storedWidth :: widths


px : Float -> String
px value =
    String.fromFloat value ++ "px"


viewAppendRows : Model -> List (Html Msg)
viewAppendRows model =
    if appendUsesSplit model then
        viewAppendRow model :: viewAppendSplitRows model

    else
        [ viewAppendRow model ]


viewAppendRow : Model -> Html Msg
viewAppendRow model =
    Html.tr [ Attr.class "append-row" ]
        [ Html.td [ Attr.class "ledger-date" ]
            [ Html.input
                [ Attr.type_ "date"
                , Attr.value model.appendDateInput
                , Events.onInput UpdateAppendDate
                , onEnter AppendTransaction
                ]
                []
            ]
        , Html.td [ Attr.class "ledger-xid muted-cell" ] [ Html.text "" ]
        , Html.td [ Attr.class "ledger-description" ]
            [ Html.input
                [ Attr.placeholder "Description"
                , Attr.value model.appendMemoInput
                , Events.onInput UpdateAppendMemo
                , onEnter AppendTransaction
                ]
                []
            ]
        , Html.td [ Attr.class "ledger-transfer" ]
            [ accountCompletionInput
                transferChoicesListId
                "Transfer"
                model.appendOtherAccountInput
                UpdateAppendOtherAccount
            ]
        , Html.td [ Attr.class "ledger-reconciled" ]
            [ Html.input
                [ Attr.type_ "checkbox"
                , Attr.checked model.appendResolvedInput
                , Attr.title "Reconciled"
                , Events.onCheck UpdateAppendResolved
                ]
                []
            ]
        , Html.td [ Attr.class "ledger-deposit" ]
            [ moneyInput "Deposit" model.appendDebitInput UpdateAppendDebit ]
        , Html.td [ Attr.class "ledger-withdrawal" ]
            [ moneyInput "Withdrawal" model.appendCreditInput UpdateAppendCredit ]
        , Html.td [ Attr.class "ledger-balance muted-cell" ] [ Html.text "" ]
        ]


viewAppendSplitRows : Model -> List (Html Msg)
viewAppendSplitRows model =
    List.indexedMap viewAppendSplitRow model.splitRows


viewAppendSplitRow : Int -> SplitLineInput -> Html Msg
viewAppendSplitRow index row =
    Html.tr [ Attr.class "append-split-row ledger-split-line" ]
        [ Html.td [ Attr.class "ledger-date row-action" ]
            [ if index == 0 then
                Html.button
                    [ Attr.type_ "button"
                    , Attr.class "secondary-action"
                    , Events.onClick AddSplitRow
                    ]
                    [ Html.text "Add" ]

              else
                Html.text ""
            ]
        , Html.td [ Attr.class "ledger-xid muted-cell" ] [ Html.text "" ]
        , Html.td [ Attr.class "ledger-description" ]
            [ Html.input
                [ Attr.placeholder "Split description"
                , Attr.value row.memo
                , Events.onInput (UpdateSplitMemo row.key)
                , onEnter AppendTransaction
                ]
                []
            ]
        , Html.td [ Attr.class "ledger-transfer" ]
            [ accountCompletionInput
                splitAccountChoicesListId
                "Split account"
                row.account
                (UpdateSplitAccount row.key)
            ]
        , Html.td [ Attr.class "ledger-reconciled muted-cell" ] [ Html.text "" ]
        , Html.td [ Attr.class "ledger-deposit" ]
            [ moneyInput "Deposit" row.debit (UpdateSplitDebit row.key) ]
        , Html.td [ Attr.class "ledger-withdrawal" ]
            [ moneyInput "Withdrawal" row.credit (UpdateSplitCredit row.key) ]
        , Html.td [ Attr.class "ledger-balance row-action" ]
            [ Html.button
                [ Attr.type_ "button"
                , Attr.class "secondary-action"
                , Events.onClick (RemoveSplitRow row.key)
                ]
                [ Html.text "Remove" ]
            ]
        ]


moneyInput : String -> String -> (String -> Msg) -> Html Msg
moneyInput placeholderText value toMsg =
    Html.input
        [ Attr.placeholder placeholderText
        , Attr.class "number-input"
        , Attr.attribute "inputmode" "decimal"
        , Attr.value value
        , Events.onInput toMsg
        , onEnter AppendTransaction
        ]
        []


accountCompletionInput : String -> String -> String -> (String -> Msg) -> Html Msg
accountCompletionInput listId placeholderText value toMsg =
    Html.input
        [ Attr.placeholder placeholderText
        , Attr.attribute "list" listId
        , Attr.value value
        , Events.onInput toMsg
        , onEnter AppendTransaction
        ]
        []


accountChoicesDatalist : String -> List String -> Html Msg
accountChoicesDatalist listId options =
    Html.node "datalist"
        [ Attr.id listId ]
        (List.map
            (\option ->
                Html.option [ Attr.value option ] []
            )
            options
        )


viewLedgerEntry : Model -> Bool -> Int -> LedgerEntry -> List (Html Msg)
viewLedgerEntry model allAccounts index entry =
    let
        parent =
            viewLedgerRow model allAccounts index entry

        splitRows =
            case selectedTransactionEdit entry.xid model of
                Just edit ->
                    let
                        realSplitRows =
                            edit.lines
                                |> List.filter (not << .primary)
                                |> List.indexedMap (viewLedgerSplitLine model edit)

                        imbalanceRows =
                            if edit.split then
                                edit
                                    |> transactionEditImbalanceRow
                                    |> Maybe.map List.singleton
                                    |> Maybe.withDefault []

                            else
                                []
                    in
                    realSplitRows ++ imbalanceRows

                Nothing ->
                    []
    in
    parent :: splitRows


selectedTransactionEdit : Int -> Model -> Maybe TransactionEdit
selectedTransactionEdit xid model =
    case model.transactionEdit of
        Just edit ->
            if edit.xid == xid then
                Just edit

            else
                Nothing

        Nothing ->
            Nothing


viewLedgerRow : Model -> Bool -> Int -> LedgerEntry -> Html Msg
viewLedgerRow model allAccounts index entry =
    let
        selection =
            ledgerEntrySelection entry

        selectedEdit =
            selectedTransactionEdit entry.xid model

        primaryLine =
            selectedEdit
                |> Maybe.andThen primaryEditLine
    in
    Html.tr
        [ Attr.classList
            [ ( "ledger-line", True )
            , ( "ledger-line-green", modBy 2 index == 0 )
            , ( "ledger-line-yellow", modBy 2 index == 1 )
            , ( "ledger-row-selected", rowIsSelected model selection )
            ]
        , Events.onClick (SelectLedgerRow selection)
        ]
        [ Html.td [ Attr.class "ledger-date" ]
            [ case selectedEdit of
                Just edit ->
                    transactionDateInput edit

                Nothing ->
                    Html.text entry.date
            ]
        , Html.td [ Attr.class "ledger-xid" ] [ Html.text (String.fromInt entry.xid) ]
        , Html.td [ Attr.class "ledger-description" ]
            [ case primaryLine of
                Just line ->
                    transactionMemoInput allAccounts line

                Nothing ->
                    Html.text (ledgerDescription allAccounts entry)
            ]
        , Html.td [ Attr.class "ledger-transfer" ]
            [ viewTransferCell model entry selectedEdit ]
        , Html.td [ Attr.class "ledger-reconciled" ]
            [ Html.text
                (if entry.reconciled then
                    "R"

                 else
                    ""
                )
            ]
        , Html.td [ Attr.class "ledger-deposit number strong" ]
            [ case primaryLine of
                Just line ->
                    transactionMoneyInput "Deposit" line.debit (UpdateTransactionDebit line.key)

                Nothing ->
                    Html.text (depositText entry.amount)
            ]
        , Html.td [ Attr.class "ledger-withdrawal number strong" ]
            [ case primaryLine of
                Just line ->
                    transactionMoneyInput "Withdrawal" line.credit (UpdateTransactionCredit line.key)

                Nothing ->
                    Html.text (withdrawalText entry.amount)
            ]
        , Html.td [ Attr.class "ledger-balance number strong" ]
            [ Html.text (maybeMoney entry.balance) ]
        ]


viewTransferCell : Model -> LedgerEntry -> Maybe TransactionEdit -> Html Msg
viewTransferCell model entry maybeEdit =
    case maybeEdit of
        Just edit ->
            if edit.split then
                Html.button
                    [ Attr.type_ "button"
                    , Attr.class "split-transfer"
                    , Events.onClick AddTransactionSplitLine
                    ]
                    [ Html.text "-- Split Transaction --" ]

            else
                case otherEditLine edit of
                    Just line ->
                        editAccountCompletionInput
                            editAccountChoicesListId
                            "Transfer"
                            line.account
                            (UpdateTransactionAccount line.key)

                    Nothing ->
                        Html.text ""

        Nothing ->
            if entry.split then
                Html.button
                    [ Attr.type_ "button"
                    , Attr.class "split-transfer"
                    , Events.onClick (SelectLedgerRow (ledgerEntrySelection entry))
                    ]
                    [ Html.text "-- Split Transaction --" ]

            else
                Html.text (Maybe.withDefault "" entry.transfer)


viewLedgerSplitLine : Model -> TransactionEdit -> Int -> TransactionEditLine -> Html Msg
viewLedgerSplitLine model edit index line =
    let
        selection =
            { kind = SplitLedgerRow, xid = edit.xid, account = line.account }
    in
    Html.tr
        [ Attr.classList
            [ ( "ledger-split-line", True )
            , ( "ledger-row-selected", rowIsSelected model selection )
            ]
        , Events.onClick (SelectLedgerRow selection)
        ]
        [ Html.td [ Attr.class "ledger-date muted-cell split-empty-date" ]
            [ if index == 0 then
                Html.button
                    [ Attr.type_ "button"
                    , Attr.class "secondary-action split-row-action"
                    , Events.onClick AddTransactionSplitLine
                    ]
                    [ Html.text "Add" ]

              else
                Html.text ""
            ]
        , Html.td [ Attr.class "ledger-xid muted-cell" ] [ Html.text (String.fromInt edit.xid) ]
        , Html.td [ Attr.class "ledger-description" ]
            [ transactionMemoInput False line ]
        , Html.td [ Attr.class "ledger-transfer" ]
            [ editAccountCompletionInput
                editAccountChoicesListId
                "Account"
                line.account
                (UpdateTransactionAccount line.key)
            ]
        , Html.td [ Attr.class "ledger-reconciled muted-cell" ] [ Html.text "" ]
        , Html.td [ Attr.class "ledger-deposit number" ]
            [ transactionMoneyInput "Deposit" line.debit (UpdateTransactionDebit line.key) ]
        , Html.td [ Attr.class "ledger-withdrawal number" ]
            [ transactionMoneyInput "Withdrawal" line.credit (UpdateTransactionCredit line.key) ]
        , Html.td [ Attr.class "ledger-balance muted-cell row-action" ]
            [ Html.button
                [ Attr.type_ "button"
                , Attr.class "secondary-action split-row-action"
                , Events.onClick (RemoveTransactionLine line.key)
                ]
                [ Html.text "Remove" ]
            ]
        ]


viewGeneralJournalPage : Model -> Html Msg
viewGeneralJournalPage model =
    Html.section [ Attr.class "panel" ]
        [ sectionHeader "General Journal"
        , Html.table [ Attr.class "data-table general-journal-table" ]
            [ Html.thead []
                [ Html.tr []
                    [ Html.th [ Attr.class "journal-date" ] [ Html.text "Date" ]
                    , Html.th [ Attr.class "journal-xid" ] [ Html.text "XID" ]
                    , Html.th [ Attr.class "journal-description" ] [ Html.text "Description" ]
                    , Html.th [ Attr.class "journal-reconciled" ] [ Html.text "R" ]
                    , Html.th [ Attr.class "journal-account" ] [ Html.text "Account" ]
                    , Html.th [ Attr.class "journal-memo" ] [ Html.text "Memo" ]
                    , Html.th [ Attr.class "journal-debit number" ] [ Html.text "Debit" ]
                    , Html.th [ Attr.class "journal-credit number" ] [ Html.text "Credit" ]
                    ]
                ]
            , Html.tbody [] (List.map viewGeneralJournalRow model.journal)
            ]
        ]


viewGeneralJournalRow : GeneralJournalRow -> Html Msg
viewGeneralJournalRow row =
    let
        firstLine =
            row.lineOrder == 1

        creditLine =
            row.credit /= Nothing
    in
    Html.tr
        [ Attr.classList
            [ ( "journal-line", True )
            , ( "journal-group-even", modBy 2 row.xid == 0 )
            , ( "journal-group-odd", modBy 2 row.xid == 1 )
            , ( "journal-first-line", firstLine )
            ]
        ]
        [ Html.td [ Attr.class "journal-date" ]
            [ Html.text
                (if firstLine then
                    row.date

                 else
                    ""
                )
            ]
        , Html.td [ Attr.class "journal-xid" ]
            [ Html.text
                (if firstLine then
                    String.fromInt row.xid

                 else
                    ""
                )
            ]
        , Html.td [ Attr.class "journal-description" ]
            [ Html.text
                (if firstLine then
                    Maybe.withDefault "" row.description

                 else
                    ""
                )
            ]
        , Html.td [ Attr.class "journal-reconciled" ]
            [ Html.text
                (if firstLine && row.reconciled then
                    "R"

                 else
                    ""
                )
            ]
        , Html.td
            [ Attr.classList
                [ ( "journal-account", True )
                , ( "journal-credit-account", creditLine )
                ]
            ]
            [ Html.text row.account ]
        , Html.td [ Attr.class "journal-memo" ]
            [ Html.text (Maybe.withDefault "" row.memo) ]
        , Html.td [ Attr.class "journal-debit number" ]
            [ Html.text (maybeMoney row.debit) ]
        , Html.td [ Attr.class "journal-credit number" ]
            [ Html.text (maybeMoney row.credit) ]
        ]


transactionEditImbalanceRow : TransactionEdit -> Maybe (Html Msg)
transactionEditImbalanceRow edit =
    transactionEditImbalanceCents edit
        |> Maybe.map
            (\imbalanceCents ->
                Html.tr
                    [ Attr.class "ledger-split-line ledger-imbalance-line" ]
                    [ Html.td [ Attr.class "ledger-date muted-cell split-empty-date" ] [ Html.text "" ]
                    , Html.td [ Attr.class "ledger-xid muted-cell" ] [ Html.text (String.fromInt edit.xid) ]
                    , Html.td [ Attr.class "ledger-description muted-cell" ] [ Html.text "" ]
                    , Html.td [ Attr.class "ledger-transfer" ] [ Html.text "Imbalance" ]
                    , Html.td [ Attr.class "ledger-reconciled muted-cell" ] [ Html.text "" ]
                    , Html.td [ Attr.class "ledger-deposit number" ]
                        [ Html.text
                            (if imbalanceCents > 0 then
                                centsToMoney imbalanceCents

                             else
                                ""
                            )
                        ]
                    , Html.td [ Attr.class "ledger-withdrawal number" ]
                        [ Html.text
                            (if imbalanceCents < 0 then
                                centsToMoney (negate imbalanceCents)

                             else
                                ""
                            )
                        ]
                    , Html.td [ Attr.class "ledger-balance muted-cell" ] [ Html.text "" ]
                    ]
            )


transactionEditImbalanceCents : TransactionEdit -> Maybe Int
transactionEditImbalanceCents edit =
    edit.lines
        |> List.map editLineAmountCentsForImbalance
        |> combineResults
        |> Result.toMaybe
        |> Maybe.andThen
            (\amounts ->
                let
                    offset =
                        negate (List.sum amounts)
                in
                if offset == 0 then
                    Nothing

                else
                    Just offset
            )


editLineAmountCentsForImbalance : TransactionEditLine -> Result String Int
editLineAmountCentsForImbalance line =
    case ( blankToNothing line.debit, blankToNothing line.credit ) of
        ( Nothing, Nothing ) ->
            Ok 0

        ( Just _, Just _ ) ->
            Err "line has both deposit and withdrawal"

        ( Just raw, Nothing ) ->
            parsePositiveAmount "Deposit" raw
                |> Result.map (\amount -> round (amount * 100))

        ( Nothing, Just raw ) ->
            parsePositiveAmount "Withdrawal" raw
                |> Result.map (\amount -> negate (round (amount * 100)))


combineResults : List (Result x a) -> Result x (List a)
combineResults results =
    case results of
        [] ->
            Ok []

        result :: rest ->
            result
                |> Result.andThen
                    (\value ->
                        combineResults rest
                            |> Result.map (\values -> value :: values)
                    )


primaryEditLine : TransactionEdit -> Maybe TransactionEditLine
primaryEditLine edit =
    edit.lines
        |> List.filter .primary
        |> List.head


otherEditLine : TransactionEdit -> Maybe TransactionEditLine
otherEditLine edit =
    edit.lines
        |> List.filter (not << .primary)
        |> List.head


transactionDateInput : TransactionEdit -> Html Msg
transactionDateInput edit =
    Html.input
        [ Attr.type_ "date"
        , Attr.class "ledger-edit-input"
        , Attr.value edit.date
        , Events.onInput UpdateTransactionDate
        , onEnter SaveSelectedTransaction
        ]
        []


transactionMemoInput : Bool -> TransactionEditLine -> Html Msg
transactionMemoInput allAccounts line =
    let
        input =
            Html.input
                [ Attr.class "ledger-edit-input"
                , Attr.value line.memo
                , Events.onInput (UpdateTransactionMemo line.key)
                , onEnter SaveSelectedTransaction
                ]
                []
    in
    if allAccounts then
        Html.div [ Attr.class "description-edit" ]
            [ Html.span [ Attr.class "account-prefix" ] [ Html.text (line.account ++ ":") ]
            , input
            ]

    else
        input


transactionMoneyInput : String -> String -> (String -> Msg) -> Html Msg
transactionMoneyInput placeholderText value toMsg =
    Html.input
        [ Attr.placeholder placeholderText
        , Attr.class "ledger-edit-input number-input"
        , Attr.attribute "inputmode" "decimal"
        , Attr.value value
        , Events.onInput toMsg
        , onEnter SaveSelectedTransaction
        ]
        []


editAccountCompletionInput : String -> String -> String -> (String -> Msg) -> Html Msg
editAccountCompletionInput listId placeholderText value toMsg =
    Html.input
        [ Attr.placeholder placeholderText
        , Attr.attribute "list" listId
        , Attr.value value
        , Events.onInput toMsg
        , onEnter SaveSelectedTransaction
        ]
        []


ledgerEntrySelection : LedgerEntry -> LedgerRowSelection
ledgerEntrySelection entry =
    { kind = ParentLedgerRow
    , xid = entry.xid
    , account = Maybe.withDefault "" entry.account
    }


ledgerSplitSelection : Int -> LedgerSplitLine -> LedgerRowSelection
ledgerSplitSelection xid line =
    { kind = SplitLedgerRow
    , xid = xid
    , account = line.account
    }


rowIsSelected : Model -> LedgerRowSelection -> Bool
rowIsSelected model selection =
    model.selectedLedgerRow == Just selection


ledgerDateInput : Model -> Int -> String -> Html Msg
ledgerDateInput model xid account =
    ledgerDateInputWithFallback
        model
        xid
        account
        (ledgerLineBaseDate xid model)


ledgerDateInputWithFallback : Model -> Int -> String -> String -> Html Msg
ledgerDateInputWithFallback model xid account fallbackDate =
    let
        edit =
            ledgerLineEditValue xid account model

        value =
            case existingLedgerEdit xid account model of
                Just _ ->
                    edit.date

                Nothing ->
                    if edit.date == "" then
                        fallbackDate

                    else
                        edit.date
    in
    Html.input
        [ Attr.type_ "date"
        , Attr.class "ledger-edit-input"
        , Attr.value value
        , Events.onInput (UpdateLedgerDate xid account)
        , onEnter (SubmitLedgerLine xid account)
        ]
        []


ledgerDescriptionInput : Model -> Bool -> Int -> String -> Html Msg
ledgerDescriptionInput model allAccounts xid account =
    let
        edit =
            ledgerLineEditValue xid account model

        input =
            Html.input
                [ Attr.class "ledger-edit-input"
                , Attr.value edit.description
                , Events.onInput (UpdateLedgerDescription xid account)
                , onEnter (SubmitLedgerLine xid account)
                ]
                []
    in
    if allAccounts then
        Html.div [ Attr.class "description-edit" ]
            [ Html.span [ Attr.class "account-prefix" ] [ Html.text (account ++ ":") ]
            , input
            ]

    else
        input


ledgerDescription : Bool -> LedgerEntry -> String
ledgerDescription allAccounts entry =
    let
        description =
            Maybe.withDefault "" entry.description
    in
    if allAccounts then
        case entry.account of
            Just account ->
                if description == "" then
                    account

                else
                    account ++ ": " ++ description

            Nothing ->
                description

    else
        description


depositText : Float -> String
depositText amount =
    if amount > 0 then
        money amount

    else
        ""


withdrawalText : Float -> String
withdrawalText amount =
    if amount < 0 then
        money (negate amount)

    else
        ""


viewBalancePage : Model -> Html Msg
viewBalancePage model =
    Html.section [ Attr.class "panel" ]
        [ Html.div [ Attr.class "report-toolbar" ]
            [ sectionHeader "Balance Sheet"
            , Html.label [ Attr.class "date-filter" ]
                [ Html.span [] [ Html.text "As of" ]
                , Html.input
                    [ Attr.type_ "date"
                    , Attr.value model.reportDateInput
                    , Events.onInput UpdateReportDate
                    ]
                    []
                ]
            , Html.button [ Attr.type_ "button", Events.onClick RefreshReport ]
                [ Html.text "Load" ]
            ]
        , Html.table [ Attr.class "data-table" ]
            [ Html.thead []
                [ Html.tr []
                    [ Html.th [] [ Html.text "Account" ]
                    , Html.th [] [ Html.text "Original" ]
                    , Html.th [] [ Html.text "Pretax" ]
                    , Html.th [] [ Html.text "Book value" ]
                    ]
                ]
            , Html.tbody [] (viewBalanceReportRows Nothing model.balance)
            ]
        ]


viewTrialBalancePage : Model -> Html Msg
viewTrialBalancePage model =
    Html.section [ Attr.class "panel" ]
        [ Html.div [ Attr.class "report-toolbar" ]
            [ sectionHeader "Trial Balance"
            , Html.label [ Attr.class "date-filter" ]
                [ Html.span [] [ Html.text "As of" ]
                , Html.input
                    [ Attr.type_ "date"
                    , Attr.value model.reportDateInput
                    , Events.onInput UpdateReportDate
                    ]
                    []
                ]
            , Html.button [ Attr.type_ "button", Events.onClick RefreshReport ]
                [ Html.text "Load" ]
            ]
        , Html.table [ Attr.class "data-table" ]
            [ Html.thead []
                [ Html.tr []
                    [ Html.th [] [ Html.text "Account" ]
                    , Html.th [] [ Html.text "Type" ]
                    , Html.th [] [ Html.text "Original" ]
                    , Html.th [ Attr.class "number" ] [ Html.text "Debit" ]
                    , Html.th [ Attr.class "number" ] [ Html.text "Credit" ]
                    ]
                ]
            , Html.tbody [] (List.map viewTrialBalanceRow model.trialBalance)
            ]
        ]


viewTrialBalanceRow : TrialBalanceRow -> Html Msg
viewTrialBalanceRow row =
    Html.tr
        [ Attr.classList
            [ ( "balance-account-row", row.rowKind == "account" )
            , ( "balance-total-row", row.rowKind == "total" )
            , ( "balance-grand-total-row", row.rowKind == "difference" )
            ]
        ]
        [ Html.td [] [ Html.text row.account ]
        , Html.td [] [ Html.text (Maybe.withDefault "" row.accountType) ]
        , Html.td [] [ Html.text (Maybe.withDefault "" row.origcurrency) ]
        , Html.td [ Attr.class "number strong" ] [ Html.text (maybeMoney row.debit) ]
        , Html.td [ Attr.class "number strong" ] [ Html.text (maybeMoney row.credit) ]
        ]


viewProfitLossPage : Model -> Html Msg
viewProfitLossPage model =
    Html.section [ Attr.class "panel" ]
        [ Html.div [ Attr.class "report-toolbar period-report-toolbar" ]
            [ sectionHeader "Profit & Loss"
            , Html.label [ Attr.class "date-filter" ]
                [ Html.span [] [ Html.text "From" ]
                , Html.input
                    [ Attr.type_ "date"
                    , Attr.value model.reportStartDateInput
                    , Events.onInput UpdateReportStartDate
                    ]
                    []
                ]
            , Html.label [ Attr.class "date-filter" ]
                [ Html.span [] [ Html.text "To" ]
                , Html.input
                    [ Attr.type_ "date"
                    , Attr.value model.reportEndDateInput
                    , Events.onInput UpdateReportEndDate
                    ]
                    []
                ]
            , Html.button [ Attr.type_ "button", Events.onClick RefreshReport ]
                [ Html.text "Load" ]
            ]
        , Html.table [ Attr.class "data-table" ]
            [ Html.thead []
                [ Html.tr []
                    [ Html.th [] [ Html.text "Account" ]
                    , Html.th [] [ Html.text "Original" ]
                    , Html.th [] [ Html.text "Pretax" ]
                    , Html.th [] [ Html.text "Book value" ]
                    ]
                ]
            , Html.tbody [] (viewBalanceReportRows Nothing model.balance)
            ]
        ]


viewCashFlowPage : Model -> Html Msg
viewCashFlowPage model =
    Html.section [ Attr.class "panel" ]
        [ Html.div [ Attr.class "report-toolbar period-report-toolbar" ]
            [ sectionHeader "Cash Flow"
            , Html.label [ Attr.class "date-filter" ]
                [ Html.span [] [ Html.text "From" ]
                , Html.input
                    [ Attr.type_ "date"
                    , Attr.value model.reportStartDateInput
                    , Events.onInput UpdateReportStartDate
                    ]
                    []
                ]
            , Html.label [ Attr.class "date-filter" ]
                [ Html.span [] [ Html.text "To" ]
                , Html.input
                    [ Attr.type_ "date"
                    , Attr.value model.reportEndDateInput
                    , Events.onInput UpdateReportEndDate
                    ]
                    []
                ]
            , Html.button [ Attr.type_ "button", Events.onClick RefreshReport ]
                [ Html.text "Load" ]
            ]
        , Html.table [ Attr.class "data-table" ]
            [ Html.thead []
                [ Html.tr []
                    [ Html.th [] [ Html.text "Account" ]
                    , Html.th [] [ Html.text "Original" ]
                    , Html.th [] [ Html.text "Pretax" ]
                    , Html.th [] [ Html.text "Book value" ]
                    ]
                ]
            , Html.tbody [] (viewBalanceReportRows Nothing model.balance)
            ]
        ]


viewBalanceReportRows : Maybe String -> List BalanceRow -> List (Html Msg)
viewBalanceReportRows previousSection rows =
    case rows of
        [] ->
            []

        row :: rest ->
            let
                sectionHeaderRows =
                    if Just row.section == previousSection || row.rowKind == "grand_total" then
                        []

                    else
                        [ viewBalanceSectionHeader row.section ]
            in
            sectionHeaderRows
                ++ [ viewBalanceRow row ]
                ++ viewBalanceReportRows (Just row.section) rest


viewBalanceSectionHeader : String -> Html Msg
viewBalanceSectionHeader section =
    Html.tr [ Attr.class "balance-section-row" ]
        [ Html.th [ Attr.colspan 4 ] [ Html.text section ] ]


viewBalanceRow : BalanceRow -> Html Msg
viewBalanceRow row =
    Html.tr
        [ Attr.classList
            [ ( "balance-account-row", row.rowKind == "account" )
            , ( "balance-computed-row", row.rowKind == "computed" )
            , ( "balance-total-row", row.rowKind == "section_total" )
            , ( "balance-grand-total-row", row.rowKind == "grand_total" )
            ]
        ]
        [ Html.td [] [ Html.text row.account ]
        , Html.td [] [ Html.text (Maybe.withDefault "" row.origcurrency) ]
        , Html.td [ Attr.class "number" ] [ Html.text (maybeMoney row.pretax) ]
        , Html.td [ Attr.class "number strong" ] [ Html.text (maybeMoney row.posttax) ]
        ]


viewAddBookPage : Model -> Html Msg
viewAddBookPage model =
    Html.section [ Attr.class "panel narrow-page" ]
        [ sectionHeader "Add Book"
        , Html.form [ Attr.class "form", Events.onSubmit SubmitBook ]
            [ fieldView "Book id" model.bookIdInput UpdateBookId "business"
            , fieldView "Name" model.bookNameInput UpdateBookName "Business"
            , fieldView "Reporting asset" model.bookAssetInput UpdateBookAsset "GBP"
            , Html.button [ Attr.type_ "submit" ] [ Html.text "Create Book" ]
            ]
        ]


viewAddAccountPage : Model -> Html Msg
viewAddAccountPage model =
    Html.section [ Attr.class "panel narrow-page" ]
        [ sectionHeader "Add Account"
        , Html.form [ Attr.class "form", Events.onSubmit SubmitAccount ]
            [ fieldView "Account" model.accountIdInput UpdateAccountId "Current Account"
            , selectField
                "Type"
                model.accountTypeInput
                UpdateAccountType
                [ ( "A", "Asset" )
                , ( "L", "Liability" )
                , ( "E", "Expense" )
                , ( "I", "Income" )
                , ( "Q", "Equity" )
                ]
            , fieldView "Asset" model.accountAssetInput UpdateAccountAsset "GBP"
            , fieldView "Pretax" model.accountPretaxInput UpdateAccountPretax "1.0"
            , fieldView "Opening" model.accountOpeningBalanceInput UpdateAccountOpeningBalance "0.00"
            , dateField "Open date" model.accountOpeningDateInput UpdateAccountOpeningDate
            , Html.button [ Attr.type_ "submit" ] [ Html.text "Create Account" ]
            ]
        ]


sectionHeader : String -> Html Msg
sectionHeader title =
    Html.div [ Attr.class "section-header" ] [ Html.h2 [] [ Html.text title ] ]


fieldView : String -> String -> (String -> Msg) -> String -> Html Msg
fieldView labelText current toMsg placeholderText =
    Html.label [ Attr.class "field" ]
        [ Html.span [] [ Html.text labelText ]
        , Html.input
            [ Attr.value current
            , Attr.placeholder placeholderText
            , Events.onInput toMsg
            ]
            []
        ]


dateField : String -> String -> (String -> Msg) -> Html Msg
dateField labelText current toMsg =
    Html.label [ Attr.class "field" ]
        [ Html.span [] [ Html.text labelText ]
        , Html.input
            [ Attr.type_ "date"
            , Attr.value current
            , Events.onInput toMsg
            ]
            []
        ]


checkboxField : String -> Bool -> (Bool -> Msg) -> Html Msg
checkboxField labelText current toMsg =
    Html.label [ Attr.class "check-field" ]
        [ Html.input
            [ Attr.type_ "checkbox"
            , Attr.checked current
            , Events.onCheck toMsg
            ]
            []
        , Html.span [] [ Html.text labelText ]
        ]


selectField : String -> String -> (String -> Msg) -> List ( String, String ) -> Html Msg
selectField labelText current toMsg options =
    Html.label [ Attr.class "field" ]
        [ Html.span [] [ Html.text labelText ]
        , Html.select
            [ Attr.value current, Events.onInput toMsg ]
            (List.map
                (\( value, label ) -> Html.option [ Attr.value value ] [ Html.text label ])
                options
            )
        ]


accountSelect : String -> (String -> Msg) -> List Account -> Html Msg
accountSelect current toMsg accounts =
    accountSelectWithPlaceholder "Transfer account" current toMsg accounts


accountSelectWithPlaceholder : String -> String -> (String -> Msg) -> List Account -> Html Msg
accountSelectWithPlaceholder placeholderText current toMsg accounts =
    Html.select
        [ Attr.value current, Events.onInput toMsg ]
        (Html.option [ Attr.value "" ] [ Html.text placeholderText ]
            :: List.map
                (\account -> Html.option [ Attr.value account.id ] [ Html.text account.id ])
                accounts
        )


loadBooks : Cmd Msg
loadBooks =
    Http.get
        { url = "/books"
        , expect = expectJsonDetailed GotBooks (Decode.list bookDecoder)
        }


loadAccounts : String -> Cmd Msg
loadAccounts bookId =
    Http.get
        { url = Url.absolute [ "books", bookId, "accounts" ] []
        , expect = expectJsonDetailed GotAccounts (Decode.list accountDecoder)
        }


loadLedger : String -> String -> Cmd Msg
loadLedger bookId accountId =
    Http.get
        { url = Url.absolute [ "books", bookId, "ledger", accountId ] []
        , expect = expectJsonDetailed GotLedger (Decode.list ledgerDecoder)
        }


loadBalance : String -> String -> Cmd Msg
loadBalance bookId asOf =
    let
        query =
            if String.trim asOf == "" then
                []

            else
                [ Url.string "as_of" asOf ]
    in
    Http.get
        { url = Url.absolute [ "books", bookId, "reports", "balance-sheet" ] query
        , expect = expectJsonDetailed GotBalance (Decode.list balanceDecoder)
        }


loadTrialBalance : String -> String -> Cmd Msg
loadTrialBalance bookId asOf =
    let
        query =
            if String.trim asOf == "" then
                []

            else
                [ Url.string "as_of" asOf ]
    in
    Http.get
        { url = Url.absolute [ "books", bookId, "reports", "trial-balance" ] query
        , expect = expectJsonDetailed GotTrialBalance (Decode.list trialBalanceDecoder)
        }


loadProfitLoss : String -> String -> String -> Cmd Msg
loadProfitLoss bookId startDate endDate =
    let
        query =
            optionalQueryDate "from" startDate
                ++ optionalQueryDate "to" endDate
    in
    Http.get
        { url = Url.absolute [ "books", bookId, "reports", "profit-loss" ] query
        , expect = expectJsonDetailed GotBalance (Decode.list balanceDecoder)
        }


loadCashFlow : String -> String -> String -> Cmd Msg
loadCashFlow bookId startDate endDate =
    let
        query =
            optionalQueryDate "from" startDate
                ++ optionalQueryDate "to" endDate
    in
    Http.get
        { url = Url.absolute [ "books", bookId, "reports", "cash-flow" ] query
        , expect = expectJsonDetailed GotBalance (Decode.list balanceDecoder)
        }


loadGeneralJournal : String -> Cmd Msg
loadGeneralJournal bookId =
    Http.get
        { url = Url.absolute [ "books", bookId, "reports", "general-journal" ] []
        , expect = expectJsonDetailed GotGeneralJournal (Decode.list generalJournalDecoder)
        }


optionalQueryDate : String -> String -> List Url.QueryParameter
optionalQueryDate name value =
    if String.trim value == "" then
        []

    else
        [ Url.string name value ]


createBook : Model -> Cmd Msg
createBook model =
    Http.post
        { url = "/books"
        , body =
            Http.jsonBody
                (Encode.object
                    [ ( "id", Encode.string (String.trim model.bookIdInput) )
                    , ( "name", Encode.string (String.trim model.bookNameInput) )
                    , ( "reporting_asset", Encode.string (String.trim model.bookAssetInput) )
                    , ( "create_standard_accounts", Encode.bool True )
                    ]
                )
        , expect = expectJsonDetailed CreatedBook bookDecoder
        }


createAccount : String -> Float -> Model -> Cmd Msg
createAccount bookId pretax model =
    let
        openingBalance =
            model.accountOpeningBalanceInput
                |> blankToNothing
                |> Maybe.andThen String.toFloat

        base =
            [ ( "id", Encode.string (String.trim model.accountIdInput) )
            , ( "type", Encode.string model.accountTypeInput )
            , ( "asset", Encode.string (String.trim model.accountAssetInput) )
            , ( "pretax", Encode.float pretax )
            ]

        openingFields =
            case openingBalance of
                Just amount ->
                    [ ( "opening_balance", Encode.float amount )
                    , ( "opening_date", Encode.string model.accountOpeningDateInput )
                    ]

                Nothing ->
                    []
    in
    Http.post
        { url = Url.absolute [ "books", bookId, "accounts" ] []
        , body = Http.jsonBody (Encode.object (base ++ openingFields))
        , expect = expectJsonDetailed CreatedAccount accountDecoder
        }


createTransaction : String -> List TransactionLineDraft -> Model -> Cmd Msg
createTransaction bookId lines model =
    Http.post
        { url = Url.absolute [ "books", bookId, "transactions" ] []
        , body =
            Http.jsonBody
                (Encode.object
                    ([ ( "date", Encode.string model.appendDateInput )
                     , ( "resolved", Encode.bool model.appendResolvedInput )
                     , ( "lines", Encode.list encodeTransactionLine lines )
                     ]
                        ++ optionalString "comment" model.appendMemoInput
                    )
                )
        , expect = expectJsonDetailed CreatedTransactionResponse createdDecoder
        }


updateTransaction : String -> TransactionEdit -> Cmd Msg
updateTransaction bookId edit =
    case validateTransactionEdit edit of
        Ok lines ->
            Http.request
                { method = "PATCH"
                , headers = []
                , url =
                    Url.absolute
                        [ "books"
                        , bookId
                        , "transactions"
                        , String.fromInt edit.xid
                        ]
                        []
                , body =
                    Http.jsonBody
                        (Encode.object
                            ([ ( "date", Encode.string edit.date )
                             , ( "resolved", Encode.bool edit.resolved )
                             , ( "lines", Encode.list encodeTransactionLine lines )
                             ]
                                ++ optionalString "comment" (transactionEditComment edit)
                            )
                        )
                , expect = expectWhateverDetailed (SavedTransaction edit.xid)
                , timeout = Nothing
                , tracker = Nothing
                }

        Err _ ->
            Cmd.none


transactionEditComment : TransactionEdit -> String
transactionEditComment edit =
    edit
        |> primaryEditLine
        |> Maybe.map .memo
        |> Maybe.withDefault ""


updateLedgerLine : String -> LedgerLineEdit -> Cmd Msg
updateLedgerLine bookId edit =
    Http.request
        { method = "PATCH"
        , headers = []
        , url =
            Url.absolute
                [ "books"
                , bookId
                , "transactions"
                , String.fromInt edit.xid
                , "lines"
                , edit.account
                ]
                []
        , body =
            Http.jsonBody
                (Encode.object
                    [ ( "date", Encode.string edit.date )
                    , ( "description", Encode.string edit.description )
                    ]
                )
        , expect = expectWhateverDetailed UpdatedLedgerLine
        , timeout = Nothing
        , tracker = Nothing
        }


encodeTransactionLine : TransactionLineDraft -> Encode.Value
encodeTransactionLine line =
    Encode.object
        ([ ( "account", Encode.string line.account )
         , ( "amount", Encode.float line.amount )
         ]
            ++ optionalString "comment" line.memo
        )


optionalString : String -> String -> List ( String, Encode.Value )
optionalString fieldName raw =
    case blankToNothing raw of
        Just value ->
            [ ( fieldName, Encode.string value ) ]

        Nothing ->
            []


expectJsonDetailed : (Result Http.Error a -> msg) -> Decoder a -> Http.Expect msg
expectJsonDetailed toMsg decoder =
    Http.expectStringResponse toMsg <|
        \response ->
            case response of
                Http.BadUrl_ url ->
                    Err (Http.BadUrl url)

                Http.Timeout_ ->
                    Err Http.Timeout

                Http.NetworkError_ ->
                    Err Http.NetworkError

                Http.BadStatus_ metadata body ->
                    Err (Http.BadBody (httpStatusMessage metadata.statusCode body))

                Http.GoodStatus_ _ body ->
                    case Decode.decodeString decoder body of
                        Ok value ->
                            Ok value

                        Err err ->
                            Err (Http.BadBody (Decode.errorToString err))


expectWhateverDetailed : (Result Http.Error () -> msg) -> Http.Expect msg
expectWhateverDetailed toMsg =
    Http.expectStringResponse toMsg <|
        \response ->
            case response of
                Http.BadUrl_ url ->
                    Err (Http.BadUrl url)

                Http.Timeout_ ->
                    Err Http.Timeout

                Http.NetworkError_ ->
                    Err Http.NetworkError

                Http.BadStatus_ metadata body ->
                    Err (Http.BadBody (httpStatusMessage metadata.statusCode body))

                Http.GoodStatus_ _ _ ->
                    Ok ()


httpStatusMessage : Int -> String -> String
httpStatusMessage statusCode body =
    let
        status =
            "HTTP error " ++ String.fromInt statusCode

        trimmed =
            String.trim body
    in
    if trimmed == "" then
        status

    else
        status ++ ": " ++ trimmed


onEnter : Msg -> Html.Attribute Msg
onEnter msg =
    Events.on "keydown"
        (Decode.field "key" Decode.string
            |> Decode.andThen
                (\key ->
                    if key == "Enter" then
                        Decode.succeed msg

                    else
                        Decode.fail "not enter"
                )
        )


bookDecoder : Decoder Book
bookDecoder =
    Decode.map3 Book
        (Decode.field "id" Decode.string)
        (Decode.field "name" Decode.string)
        (Decode.field "reporting_asset" Decode.string)


accountDecoder : Decoder Account
accountDecoder =
    Decode.map6 Account
        (Decode.field "book_id" Decode.string)
        (Decode.field "id" Decode.string)
        (Decode.field "type" Decode.string)
        (Decode.field "asset" Decode.string)
        (Decode.field "pretax" Decode.float)
        (Decode.field "comment" (Decode.nullable Decode.string))


ledgerDecoder : Decoder LedgerEntry
ledgerDecoder =
    Decode.map8
        (\date xid account description transfer reconciled amount balance ->
            Decode.map2
                (LedgerEntry
                    date
                    xid
                    account
                    description
                    transfer
                    reconciled
                    amount
                    balance
                )
                (Decode.field "split" Decode.bool)
                (Decode.field "split_lines" (Decode.list ledgerSplitLineDecoder))
        )
        (Decode.field "date" Decode.string)
        (Decode.field "xid" Decode.int)
        (Decode.field "account" (Decode.nullable Decode.string))
        (Decode.field "description" (Decode.nullable Decode.string))
        (Decode.field "transfer" (Decode.nullable Decode.string))
        (Decode.field "reconciled" Decode.bool)
        (Decode.field "amount" Decode.float)
        (Decode.field "balance" (Decode.nullable Decode.float))
        |> Decode.andThen identity


ledgerSplitLineDecoder : Decoder LedgerSplitLine
ledgerSplitLineDecoder =
    Decode.map3 LedgerSplitLine
        (Decode.field "account" Decode.string)
        (Decode.field "description" (Decode.nullable Decode.string))
        (Decode.field "amount" Decode.float)


balanceDecoder : Decoder BalanceRow
balanceDecoder =
    Decode.map8
        (\bookId section sectionOrder rowOrder rowKind account accountType origcurrency ->
            Decode.map2
                (BalanceRow
                    bookId
                    section
                    sectionOrder
                    rowOrder
                    rowKind
                    account
                    accountType
                    origcurrency
                )
                (Decode.field "pretax" (Decode.nullable Decode.float))
                (Decode.field "posttax" (Decode.nullable Decode.float))
        )
        (Decode.field "book_id" Decode.string)
        (Decode.field "section" Decode.string)
        (Decode.field "section_order" Decode.int)
        (Decode.field "row_order" Decode.int)
        (Decode.field "row_kind" Decode.string)
        (Decode.field "account" Decode.string)
        (Decode.field "account_type" (Decode.nullable Decode.string))
        (Decode.field "origcurrency" (Decode.nullable Decode.string))
        |> Decode.andThen identity


trialBalanceDecoder : Decoder TrialBalanceRow
trialBalanceDecoder =
    Decode.map8 TrialBalanceRow
        (Decode.field "book_id" Decode.string)
        (Decode.field "row_order" Decode.int)
        (Decode.field "row_kind" Decode.string)
        (Decode.field "account" Decode.string)
        (Decode.field "account_type" (Decode.nullable Decode.string))
        (Decode.field "origcurrency" (Decode.nullable Decode.string))
        (Decode.field "debit" (Decode.nullable Decode.float))
        (Decode.field "credit" (Decode.nullable Decode.float))


generalJournalDecoder : Decoder GeneralJournalRow
generalJournalDecoder =
    Decode.map8
        (\bookId date xid description reconciled lineOrder lineId account ->
            Decode.map4
                (GeneralJournalRow
                    bookId
                    date
                    xid
                    description
                    reconciled
                    lineOrder
                    lineId
                    account
                )
                (Decode.field "account_type" Decode.string)
                (Decode.field "memo" (Decode.nullable Decode.string))
                (Decode.field "debit" (Decode.nullable Decode.float))
                (Decode.field "credit" (Decode.nullable Decode.float))
        )
        (Decode.field "book_id" Decode.string)
        (Decode.field "date" Decode.string)
        (Decode.field "xid" Decode.int)
        (Decode.field "description" (Decode.nullable Decode.string))
        (Decode.field "reconciled" Decode.bool)
        (Decode.field "line_order" Decode.int)
        (Decode.field "line_id" Decode.int)
        (Decode.field "account" Decode.string)
        |> Decode.andThen identity


createdDecoder : Decoder CreatedTransaction
createdDecoder =
    Decode.map3 CreatedTransaction
        (Decode.field "book_id" Decode.string)
        (Decode.field "xid" Decode.int)
        (Decode.field "resolved" Decode.bool)


setError : Http.Error -> Model -> Model
setError err model =
    { model | status = errorToString err, loading = False }


errorToString : Http.Error -> String
errorToString err =
    case err of
        Http.BadUrl url ->
            "Bad URL: " ++ url

        Http.Timeout ->
            "Request timed out"

        Http.NetworkError ->
            "Network error"

        Http.BadStatus code ->
            "HTTP error " ++ String.fromInt code

        Http.BadBody reason ->
            if String.startsWith "HTTP error " reason then
                reason

            else
                "Bad response: " ++ reason


parseFloat : String -> Maybe Float
parseFloat raw =
    raw |> String.trim |> String.toFloat


blankToNothing : String -> Maybe String
blankToNothing value =
    let
        trimmed =
            String.trim value
    in
    if trimmed == "" then
        Nothing

    else
        Just trimmed


maybeMoney : Maybe Float -> String
maybeMoney value =
    value |> Maybe.map money |> Maybe.withDefault ""


centsToMoney : Int -> String
centsToMoney cents =
    toFloat cents / 100
        |> money


money : Float -> String
money value =
    let
        rounded =
            toFloat (round (value * 100)) / 100
    in
    String.fromFloat rounded


reportValue : Page -> String
reportValue page =
    case page of
        GeneralJournalPage ->
            "general-journal"

        BalanceSheetPage ->
            "balance"

        TrialBalancePage ->
            "trial-balance"

        ProfitLossPage ->
            "profit-loss"

        CashFlowPage ->
            "cash-flow"

        _ ->
            "ledger"


splitTransferLabel : String
splitTransferLabel =
    "-- Split Transaction --"


transferChoicesListId : String
transferChoicesListId =
    "transfer-account-choices"


splitAccountChoicesListId : String
splitAccountChoicesListId =
    "split-account-choices"


editAccountChoicesListId : String
editAccountChoicesListId =
    "edit-account-choices"


addBookValue : String
addBookValue =
    "__add_book__"


addAccountValue : String
addAccountValue =
    "__add_account__"
