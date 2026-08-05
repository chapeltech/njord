module Main exposing (main)

import Browser
import Dict exposing (Dict)
import Html exposing (Html)
import Html.Attributes as Attr
import Html.Events as Events
import Http
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import String


main : Program () Model Msg
main =
    Browser.element
        { init = \_ -> ( initialModel, loadShell )
        , update = update
        , subscriptions = \_ -> Sub.none
        , view = view
        }


type Page
    = ShellPage
    | LedgerPage
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
    , selected : Bool
    }


type alias Account =
    { bookId : String
    , id : String
    , accountType : String
    , asset : String
    , pretax : Float
    }


type alias ReportOption =
    { id : String
    , name : String
    }


type alias TransactionLine =
    { account : String
    , comment : Maybe String
    , amount : Float
    }


type alias LedgerEntry =
    { date : String
    , xid : Int
    , account : String
    , description : Maybe String
    , transactionComment : Maybe String
    , transfer : Maybe String
    , reconciled : Bool
    , amount : Float
    , balance : Float
    , split : Bool
    , lines : List TransactionLine
    }


type alias JournalRow =
    { date : String
    , xid : Int
    , description : Maybe String
    , reconciled : Bool
    , lineOrder : Int
    , account : String
    , memo : Maybe String
    , debit : Maybe Float
    , credit : Maybe Float
    }


type alias ReportRow =
    { section : String
    , rowKind : String
    , account : String
    , originalCurrency : Maybe String
    , pretax : Maybe Float
    , posttax : Maybe Float
    }


type alias TrialRow =
    { rowKind : String
    , account : String
    , originalCurrency : Maybe String
    , debit : Maybe Float
    , credit : Maybe Float
    }


type alias DraftLine =
    { key : Int
    , account : String
    , amount : String
    , memo : String
    }


type alias LedgerEdit =
    { xid : Int
    , account : String
    , date : String
    , description : String
    }


type alias Preview =
    { valid : Bool
    , errorCode : Maybe String
    , errorMessage : Maybe String
    , imbalance : Dict String Float
    , normalizedTransaction : Maybe NormalizedTransaction
    }


type alias NormalizedTransaction =
    { date : String
    , resolved : Bool
    , comment : Maybe String
    , lines : List TransactionLine
    }


type alias PageContext =
    { page : String
    , asOf : Maybe String
    , fromDate : Maybe String
    , toDate : Maybe String
    , reportingAsset : Maybe String
    , accountType : Maybe String
    , asset : Maybe String
    , pretax : Maybe Float
    , openingDate : Maybe String
    , validationMessages : List String
    }


type alias MutationResult =
    { bookId : String
    , xid : Int
    , resolved : Bool
    }


type Component
    = BookComponent Book
    | AccountComponent Account
    | ReportOptionComponent ReportOption
    | TransferOptionComponent String
    | LedgerComponent LedgerEntry
    | JournalComponent JournalRow
    | ReportComponent ReportRow
    | TrialComponent TrialRow
    | AssetComponent String
    | AccountTypeComponent String
    | PageContextComponent PageContext
    | OtherComponent


type alias Model =
    { page : Page
    , books : List Book
    , accounts : List Account
    , reportOptions : List ReportOption
    , transferAccounts : List String
    , assets : List String
    , accountTypes : List String
    , selectedBook : Maybe String
    , selectedAccount : Maybe String
    , ledger : List LedgerEntry
    , journal : List JournalRow
    , reportRows : List ReportRow
    , trialRows : List TrialRow
    , reportDate : String
    , reportFrom : String
    , reportTo : String
    , bookIdInput : String
    , bookNameInput : String
    , bookAssetInput : String
    , accountIdInput : String
    , accountTypeInput : String
    , accountAssetInput : String
    , accountPretaxInput : String
    , openingBalanceInput : String
    , openingDateInput : String
    , transactionXid : Maybe Int
    , transactionDate : String
    , transactionResolved : Bool
    , transactionComment : String
    , draftLines : List DraftLine
    , nextDraftKey : Int
    , preview : Maybe Preview
    , ledgerEdit : Maybe LedgerEdit
    , expandedTransactions : List Int
    , pageValidation : List String
    , loading : Bool
    , status : String
    }


initialModel : Model
initialModel =
    { page = ShellPage
    , books = []
    , accounts = []
    , reportOptions = []
    , transferAccounts = []
    , assets = []
    , accountTypes = []
    , selectedBook = Nothing
    , selectedAccount = Nothing
    , ledger = []
    , journal = []
    , reportRows = []
    , trialRows = []
    , reportDate = ""
    , reportFrom = ""
    , reportTo = ""
    , bookIdInput = ""
    , bookNameInput = ""
    , bookAssetInput = ""
    , accountIdInput = ""
    , accountTypeInput = ""
    , accountAssetInput = ""
    , accountPretaxInput = ""
    , openingBalanceInput = ""
    , openingDateInput = ""
    , transactionXid = Nothing
    , transactionDate = ""
    , transactionResolved = True
    , transactionComment = ""
    , draftLines = [ emptyDraft 1, emptyDraft 2 ]
    , nextDraftKey = 3
    , preview = Nothing
    , ledgerEdit = Nothing
    , expandedTransactions = []
    , pageValidation = []
    , loading = True
    , status = "Loading"
    }


emptyDraft : Int -> DraftLine
emptyDraft key =
    { key = key, account = "", amount = "", memo = "" }


type Msg
    = GotPage Page (Maybe String) (Result Http.Error (List Component))
    | SelectBook String
    | SelectAccount String
    | SelectReport String
    | UpdateReportDate String
    | UpdateReportFrom String
    | UpdateReportTo String
    | RefreshReport
    | UpdateBookId String
    | UpdateBookName String
    | UpdateBookAsset String
    | SubmitBook
    | BookCreated (Result Http.Error (List Book))
    | UpdateAccountId String
    | UpdateAccountType String
    | UpdateAccountAsset String
    | UpdateAccountPretax String
    | UpdateOpeningBalance String
    | UpdateOpeningDate String
    | SubmitAccount
    | AccountCreated (Result Http.Error (List Account))
    | NewTransaction
    | EditTransaction LedgerEntry
    | UpdateTransactionDate String
    | UpdateTransactionResolved Bool
    | UpdateTransactionComment String
    | AddDraftLine
    | RemoveDraftLine Int
    | UpdateDraftAccount Int String
    | UpdateDraftAmount Int String
    | UpdateDraftMemo Int String
    | PreviewTransaction
    | PreviewedTransaction (Result Http.Error (List Preview))
    | SubmitTransaction
    | TransactionSaved (Result Http.Error (List MutationResult))
    | BeginLedgerEdit LedgerEntry
    | UpdateLedgerEditDate String
    | UpdateLedgerEditDescription String
    | SaveLedgerEdit
    | LedgerLineSaved (Result Http.Error (List LedgerEdit))
    | ToggleTransaction Int


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        GotPage requestedPage requestedAccount result ->
            case result of
                Err err ->
                    ( httpError err model, Cmd.none )

                Ok components ->
                    let
                        next =
                            applyPage requestedPage components model

                        selectedBook =
                            next.selectedBook

                        firstAccount =
                            List.head next.accounts |> Maybe.map .id
                    in
                    case ( selectedBook, firstAccount ) of
                        ( Just bookId, Just accountId ) ->
                            if requestedPage == ShellPage || (requestedPage == LedgerPage && requestedAccount == Nothing) then
                                ( { next | selectedAccount = Just accountId, loading = True }
                                , loadLedger bookId accountId
                                )

                            else
                                ( { next | loading = False, status = "Ready" }, Cmd.none )

                        _ ->
                            ( { next | loading = False, status = "Ready" }, Cmd.none )

        SelectBook raw ->
            if raw == addBookValue then
                ( loadingModel AddBookPage "Loading add-book page" model, loadAddBookPage )

            else
                let
                    nextPage =
                        if model.page == AddBookPage then
                            LedgerPage

                        else
                            model.page

                    next =
                        { model
                            | selectedBook = Just raw
                            , selectedAccount = Nothing
                            , ledgerEdit = Nothing
                            , transactionXid = Nothing
                            , preview = Nothing
                        }
                in
                ( loadingModel nextPage "Loading book" next
                , loadCurrentPage nextPage raw Nothing next
                )

        SelectAccount raw ->
            if raw == addAccountValue then
                case model.selectedBook of
                    Just bookId ->
                        ( loadingModel AddAccountPage "Loading add-account page" model
                        , loadAddAccountPage bookId
                        )

                    Nothing ->
                        ( { model | status = "Select a book first" }, Cmd.none )

            else
                case model.selectedBook of
                    Just bookId ->
                        ( loadingModel LedgerPage "Loading ledger" { model | selectedAccount = Just raw }
                        , loadLedger bookId raw
                        )

                    Nothing ->
                        ( model, Cmd.none )

        SelectReport reportId ->
            case model.selectedBook of
                Nothing ->
                    ( { model | status = "Select a book first" }, Cmd.none )

                Just bookId ->
                    let
                        nextPage =
                            pageFromReport reportId
                    in
                    ( loadingModel nextPage "Loading report" model
                    , loadCurrentPage nextPage bookId model.selectedAccount model
                    )

        UpdateReportDate value ->
            ( { model | reportDate = value, pageValidation = [] }, Cmd.none )

        UpdateReportFrom value ->
            ( { model | reportFrom = value, pageValidation = [] }, Cmd.none )

        UpdateReportTo value ->
            ( { model | reportTo = value, pageValidation = [] }, Cmd.none )

        RefreshReport ->
            case model.selectedBook of
                Just bookId ->
                    ( loadingModel model.page "Refreshing report" model
                    , loadCurrentPage model.page bookId model.selectedAccount model
                    )

                Nothing ->
                    ( model, Cmd.none )

        UpdateBookId value ->
            ( { model | bookIdInput = value }, Cmd.none )

        UpdateBookName value ->
            ( { model | bookNameInput = value }, Cmd.none )

        UpdateBookAsset value ->
            ( { model | bookAssetInput = value }, Cmd.none )

        SubmitBook ->
            ( { model | loading = True, status = "Creating book" }, createBook model )

        BookCreated result ->
            case result |> Result.andThen firstResult of
                Err err ->
                    ( httpError err model, Cmd.none )

                Ok book ->
                    ( { model | selectedBook = Just book.id, selectedAccount = Nothing, loading = True }
                    , loadLedger book.id ""
                    )

        UpdateAccountId value ->
            ( { model | accountIdInput = value }, Cmd.none )

        UpdateAccountType value ->
            ( { model | accountTypeInput = value }, Cmd.none )

        UpdateAccountAsset value ->
            ( { model | accountAssetInput = value }, Cmd.none )

        UpdateAccountPretax value ->
            ( { model | accountPretaxInput = value }, Cmd.none )

        UpdateOpeningBalance value ->
            ( { model | openingBalanceInput = value }, Cmd.none )

        UpdateOpeningDate value ->
            ( { model | openingDateInput = value }, Cmd.none )

        SubmitAccount ->
            case model.selectedBook of
                Just bookId ->
                    ( { model | loading = True, status = "Creating account" }
                    , createAccount bookId model
                    )

                Nothing ->
                    ( { model | status = "Select a book first" }, Cmd.none )

        AccountCreated result ->
            case result |> Result.andThen firstResult of
                Err err ->
                    ( httpError err model, Cmd.none )

                Ok account ->
                    ( { model | selectedAccount = Just account.id, loading = True }
                    , loadLedger account.bookId account.id
                    )

        NewTransaction ->
            ( resetTransactionEditor model, Cmd.none )

        EditTransaction entry ->
            let
                drafts =
                    entry.lines
                        |> List.indexedMap
                            (\index line ->
                                { key = index + 1
                                , account = line.account
                                , amount = String.fromFloat line.amount
                                , memo = Maybe.withDefault "" line.comment
                                }
                            )
            in
            ( { model
                | transactionXid = Just entry.xid
                , transactionDate = entry.date
                , transactionResolved = entry.reconciled
                , transactionComment = Maybe.withDefault "" entry.transactionComment
                , draftLines = drafts
                , nextDraftKey = List.length drafts + 1
                , preview = Nothing
              }
            , Cmd.none
            )

        UpdateTransactionDate value ->
            ( invalidatePreview { model | transactionDate = value }, Cmd.none )

        UpdateTransactionResolved value ->
            ( invalidatePreview { model | transactionResolved = value }, Cmd.none )

        UpdateTransactionComment value ->
            ( invalidatePreview { model | transactionComment = value }, Cmd.none )

        AddDraftLine ->
            ( invalidatePreview
                { model
                    | draftLines = model.draftLines ++ [ emptyDraft model.nextDraftKey ]
                    , nextDraftKey = model.nextDraftKey + 1
                }
            , Cmd.none
            )

        RemoveDraftLine key ->
            ( invalidatePreview { model | draftLines = List.filter (\line -> line.key /= key) model.draftLines }
            , Cmd.none
            )

        UpdateDraftAccount key value ->
            ( updateDraft key (\line -> { line | account = value }) model, Cmd.none )

        UpdateDraftAmount key value ->
            ( updateDraft key (\line -> { line | amount = value }) model, Cmd.none )

        UpdateDraftMemo key value ->
            ( updateDraft key (\line -> { line | memo = value }) model, Cmd.none )

        PreviewTransaction ->
            case model.selectedBook of
                Just bookId ->
                    ( { model | loading = True, status = "Checking transaction" }
                    , previewTransaction bookId model
                    )

                Nothing ->
                    ( model, Cmd.none )

        PreviewedTransaction result ->
            case result |> Result.andThen firstResult of
                Err err ->
                    ( httpError err model, Cmd.none )

                Ok preview ->
                    ( { model | preview = Just preview, loading = False, status = "Preview updated" }
                    , Cmd.none
                    )

        SubmitTransaction ->
            case model.selectedBook of
                Just bookId ->
                    ( { model | loading = True, status = "Saving transaction" }
                    , saveTransaction bookId model
                    )

                Nothing ->
                    ( model, Cmd.none )

        TransactionSaved result ->
            case result |> Result.andThen firstResult of
                Err err ->
                    ( httpError err model, Cmd.none )

                Ok _ ->
                    reloadLedger "Transaction saved" (resetTransactionEditor model)

        BeginLedgerEdit entry ->
            ( { model
                | ledgerEdit =
                    Just
                        { xid = entry.xid
                        , account = entry.account
                        , date = entry.date
                        , description = Maybe.withDefault "" entry.description
                        }
              }
            , Cmd.none
            )

        UpdateLedgerEditDate value ->
            ( { model | ledgerEdit = Maybe.map (\edit -> { edit | date = value }) model.ledgerEdit }
            , Cmd.none
            )

        UpdateLedgerEditDescription value ->
            ( { model | ledgerEdit = Maybe.map (\edit -> { edit | description = value }) model.ledgerEdit }
            , Cmd.none
            )

        SaveLedgerEdit ->
            case ( model.selectedBook, model.ledgerEdit ) of
                ( Just bookId, Just edit ) ->
                    ( { model | loading = True, status = "Saving ledger line" }
                    , updateLedgerLine bookId edit
                    )

                _ ->
                    ( model, Cmd.none )

        LedgerLineSaved result ->
            case result |> Result.andThen firstResult of
                Err err ->
                    ( httpError err model, Cmd.none )

                Ok _ ->
                    reloadLedger "Ledger line saved" { model | ledgerEdit = Nothing }

        ToggleTransaction xid ->
            if List.member xid model.expandedTransactions then
                ( { model | expandedTransactions = List.filter ((/=) xid) model.expandedTransactions }, Cmd.none )

            else
                ( { model | expandedTransactions = xid :: model.expandedTransactions }, Cmd.none )


loadingModel : Page -> String -> Model -> Model
loadingModel page status model =
    { model | page = page, loading = True, status = status }


invalidatePreview : Model -> Model
invalidatePreview model =
    { model | preview = Nothing }


updateDraft : Int -> (DraftLine -> DraftLine) -> Model -> Model
updateDraft key change model =
    invalidatePreview
        { model
            | draftLines =
                List.map
                    (\line ->
                        if line.key == key then
                            change line

                        else
                            line
                    )
                    model.draftLines
        }


resetTransactionEditor : Model -> Model
resetTransactionEditor model =
    { model
        | transactionXid = Nothing
        , transactionDate = ""
        , transactionResolved = True
        , transactionComment = ""
        , draftLines = [ emptyDraft 1, emptyDraft 2 ]
        , nextDraftKey = 3
        , preview = Nothing
    }


reloadLedger : String -> Model -> ( Model, Cmd Msg )
reloadLedger status model =
    case ( model.selectedBook, model.selectedAccount ) of
        ( Just bookId, Just accountId ) ->
            ( { model | loading = True, status = status }, loadLedger bookId accountId )

        _ ->
            ( { model | loading = False, status = status }, Cmd.none )


firstResult : List a -> Result Http.Error a
firstResult rows =
    case rows of
        first :: _ ->
            Ok first

        [] ->
            Err (Http.BadBody "The database function returned no rows")


httpError : Http.Error -> Model -> Model
httpError err model =
    { model | loading = False, status = errorToString err }


applyPage : Page -> List Component -> Model -> Model
applyPage page components model =
    let
        books =
            filterComponents (\component -> case component of
                BookComponent value -> Just value
                _ -> Nothing
            ) components

        accounts =
            filterComponents (\component -> case component of
                AccountComponent value -> Just value
                _ -> Nothing
            ) components

        selectedBook =
            if List.any (\book -> Just book.id == model.selectedBook) books then
                model.selectedBook

            else
                books
                    |> List.filter .selected
                    |> List.head
                    |> Maybe.withDefault (Maybe.withDefault fallbackBook (List.head books))
                    |> .id
                    |> nonBlankMaybe

        selectedAccount =
            if List.any (\account -> Just account.id == model.selectedAccount) accounts then
                model.selectedAccount

            else
                Nothing

        pageContext =
            filterComponents pageContextOption components |> List.head

        pageModel =
            { model
                | page = page
                , books = books
                , accounts = accounts
                , reportOptions = filterComponents reportOption components
                , transferAccounts = filterComponents transferOption components
                , assets = filterComponents assetOption components
                , accountTypes = filterComponents accountTypeOption components
                , selectedBook = selectedBook
                , selectedAccount = selectedAccount
                , ledger = filterComponents ledgerOption components
                , journal = filterComponents journalOption components
                , reportRows = filterComponents reportRowOption components
                , trialRows = filterComponents trialRowOption components
                , pageValidation = []
            }
    in
    applyPageContext page pageContext pageModel


fallbackBook : Book
fallbackBook =
    { id = "", name = "", reportingAsset = "GBP", selected = False }


filterComponents : (Component -> Maybe a) -> List Component -> List a
filterComponents select components =
    List.filterMap select components


reportOption : Component -> Maybe ReportOption
reportOption component =
    case component of
        ReportOptionComponent value -> Just value
        _ -> Nothing


transferOption : Component -> Maybe String
transferOption component =
    case component of
        TransferOptionComponent value -> Just value
        _ -> Nothing


assetOption : Component -> Maybe String
assetOption component =
    case component of
        AssetComponent value -> Just value
        _ -> Nothing


accountTypeOption : Component -> Maybe String
accountTypeOption component =
    case component of
        AccountTypeComponent value -> Just value
        _ -> Nothing


ledgerOption : Component -> Maybe LedgerEntry
ledgerOption component =
    case component of
        LedgerComponent value -> Just value
        _ -> Nothing


journalOption : Component -> Maybe JournalRow
journalOption component =
    case component of
        JournalComponent value -> Just value
        _ -> Nothing


reportRowOption : Component -> Maybe ReportRow
reportRowOption component =
    case component of
        ReportComponent value -> Just value
        _ -> Nothing


trialRowOption : Component -> Maybe TrialRow
trialRowOption component =
    case component of
        TrialComponent value -> Just value
        _ -> Nothing


pageContextOption : Component -> Maybe PageContext
pageContextOption component =
    case component of
        PageContextComponent value -> Just value
        _ -> Nothing


applyPageContext : Page -> Maybe PageContext -> Model -> Model
applyPageContext page context model =
    case context of
        Nothing ->
            model

        Just value ->
            let
                pageModel =
                    { model | pageValidation = value.validationMessages }
            in
            case page of
                BalanceSheetPage ->
                    { pageModel | reportDate = Maybe.withDefault "" value.asOf }

                TrialBalancePage ->
                    { pageModel | reportDate = Maybe.withDefault "" value.asOf }

                ProfitLossPage ->
                    { pageModel
                        | reportFrom = Maybe.withDefault "" value.fromDate
                        , reportTo = Maybe.withDefault "" value.toDate
                    }

                CashFlowPage ->
                    { pageModel
                        | reportFrom = Maybe.withDefault "" value.fromDate
                        , reportTo = Maybe.withDefault "" value.toDate
                    }

                AddBookPage ->
                    { pageModel
                        | bookAssetInput = Maybe.withDefault model.bookAssetInput value.reportingAsset
                    }

                AddAccountPage ->
                    { pageModel
                        | accountTypeInput = Maybe.withDefault model.accountTypeInput value.accountType
                        , accountAssetInput = Maybe.withDefault model.accountAssetInput value.asset
                        , accountPretaxInput = Maybe.map String.fromFloat value.pretax |> Maybe.withDefault model.accountPretaxInput
                        , openingDateInput = Maybe.withDefault model.openingDateInput value.openingDate
                    }

                _ ->
                    pageModel


nonBlankMaybe : String -> Maybe String
nonBlankMaybe value =
    if String.trim value == "" then
        Nothing

    else
        Just value


pageFromReport : String -> Page
pageFromReport reportId =
    case reportId of
        "general-journal" -> GeneralJournalPage
        "balance-sheet" -> BalanceSheetPage
        "trial-balance" -> TrialBalancePage
        "profit-loss" -> ProfitLossPage
        "cash-flow" -> CashFlowPage
        _ -> LedgerPage


loadCurrentPage : Page -> String -> Maybe String -> Model -> Cmd Msg
loadCurrentPage page bookId accountId model =
    case page of
        LedgerPage ->
            loadLedger bookId (Maybe.withDefault "" accountId)

        GeneralJournalPage ->
            loadGeneralJournal bookId

        BalanceSheetPage ->
            loadBalanceSheet bookId model.reportDate

        TrialBalancePage ->
            loadTrialBalance bookId model.reportDate

        ProfitLossPage ->
            loadProfitLoss bookId model.reportFrom model.reportTo

        CashFlowPage ->
            loadCashFlow bookId model.reportFrom model.reportTo

        AddAccountPage ->
            loadAddAccountPage bookId

        AddBookPage ->
            loadAddBookPage

        ShellPage ->
            loadShell


loadShell : Cmd Msg
loadShell =
    pageRpc ShellPage Nothing "shell_page" (Encode.object [])


loadLedger : String -> String -> Cmd Msg
loadLedger bookId accountId =
    pageRpc LedgerPage (nonBlankMaybe accountId) "ledger_page"
        (Encode.object
            [ ( "p_book_id", Encode.string bookId )
            , ( "p_account_id", Encode.string accountId )
            ]
        )


loadGeneralJournal : String -> Cmd Msg
loadGeneralJournal bookId =
    pageRpc GeneralJournalPage Nothing "general_journal_page"
        (Encode.object [ ( "p_book_id", Encode.string bookId ) ])


loadBalanceSheet : String -> String -> Cmd Msg
loadBalanceSheet bookId asOf =
    pageRpc BalanceSheetPage Nothing "balance_sheet_page"
        (Encode.object
            [ ( "p_book_id", Encode.string bookId )
            , ( "p_as_of", optionalEncodeString asOf )
            ]
        )


loadTrialBalance : String -> String -> Cmd Msg
loadTrialBalance bookId asOf =
    pageRpc TrialBalancePage Nothing "trial_balance_page"
        (Encode.object
            [ ( "p_book_id", Encode.string bookId )
            , ( "p_as_of", optionalEncodeString asOf )
            ]
        )


loadProfitLoss : String -> String -> String -> Cmd Msg
loadProfitLoss bookId fromDate toDate =
    pageRpc ProfitLossPage Nothing "profit_loss_page"
        (Encode.object
            [ ( "p_book_id", Encode.string bookId )
            , ( "p_from", optionalEncodeString fromDate )
            , ( "p_to", optionalEncodeString toDate )
            ]
        )


loadCashFlow : String -> String -> String -> Cmd Msg
loadCashFlow bookId fromDate toDate =
    pageRpc CashFlowPage Nothing "cash_flow_page"
        (Encode.object
            [ ( "p_book_id", Encode.string bookId )
            , ( "p_from", optionalEncodeString fromDate )
            , ( "p_to", optionalEncodeString toDate )
            ]
        )


loadAddBookPage : Cmd Msg
loadAddBookPage =
    pageRpc AddBookPage Nothing "add_book_page" (Encode.object [])


loadAddAccountPage : String -> Cmd Msg
loadAddAccountPage bookId =
    pageRpc AddAccountPage Nothing "add_account_page"
        (Encode.object [ ( "p_book_id", Encode.string bookId ) ])


pageRpc : Page -> Maybe String -> String -> Encode.Value -> Cmd Msg
pageRpc page requestedAccount functionName body =
    rpc functionName body componentListDecoder (GotPage page requestedAccount)


createBook : Model -> Cmd Msg
createBook model =
    rpc "create_book"
        (Encode.object
            [ ( "p_id", Encode.string (String.trim model.bookIdInput) )
            , ( "p_name", Encode.string (String.trim model.bookNameInput) )
            , ( "p_reporting_asset", Encode.string model.bookAssetInput )
            ]
        )
        (Decode.list bookDecoder)
        BookCreated


createAccount : String -> Model -> Cmd Msg
createAccount bookId model =
    rpc "create_account"
        (Encode.object
            [ ( "p_book_id", Encode.string bookId )
            , ( "p_id", Encode.string (String.trim model.accountIdInput) )
            , ( "p_type", Encode.string model.accountTypeInput )
            , ( "p_asset", Encode.string model.accountAssetInput )
            , ( "p_pretax", Encode.string model.accountPretaxInput )
            , ( "p_comment", Encode.null )
            , ( "p_opening_balance", optionalEncodeString model.openingBalanceInput )
            , ( "p_opening_date", optionalEncodeString model.openingDateInput )
            ]
        )
        (Decode.list accountDecoder)
        AccountCreated


previewTransaction : String -> Model -> Cmd Msg
previewTransaction bookId model =
    rpc "preview_transaction"
        (Encode.object
            [ ( "p_book_id", Encode.string bookId )
            , ( "p_transaction", encodeTransaction model )
            ]
        )
        (Decode.list previewDecoder)
        PreviewedTransaction


saveTransaction : String -> Model -> Cmd Msg
saveTransaction bookId model =
    case model.transactionXid of
        Nothing ->
            rpc "create_transaction"
                (Encode.object
                    [ ( "p_book_id", Encode.string bookId )
                    , ( "p_transaction", encodeTransaction model )
                    ]
                )
                (Decode.list mutationResultDecoder)
                TransactionSaved

        Just xid ->
            rpc "replace_transaction"
                (Encode.object
                    [ ( "p_book_id", Encode.string bookId )
                    , ( "p_xid", Encode.int xid )
                    , ( "p_transaction", encodeTransaction model )
                    ]
                )
                (Decode.list mutationResultDecoder)
                TransactionSaved


updateLedgerLine : String -> LedgerEdit -> Cmd Msg
updateLedgerLine bookId edit =
    rpc "update_ledger_line"
        (Encode.object
            [ ( "p_book_id", Encode.string bookId )
            , ( "p_xid", Encode.int edit.xid )
            , ( "p_account_id", Encode.string edit.account )
            , ( "p_date", Encode.string edit.date )
            , ( "p_description", Encode.string edit.description )
            ]
        )
        (Decode.list ledgerEditDecoder)
        LedgerLineSaved


encodeTransaction : Model -> Encode.Value
encodeTransaction model =
    Encode.object
        [ ( "date", Encode.string model.transactionDate )
        , ( "resolved", Encode.bool model.transactionResolved )
        , ( "comment", Encode.string model.transactionComment )
        , ( "lines", Encode.list encodeDraftLine model.draftLines )
        ]


encodeDraftLine : DraftLine -> Encode.Value
encodeDraftLine line =
    Encode.object
        [ ( "account", Encode.string line.account )
        , ( "amount", Encode.string line.amount )
        , ( "comment", Encode.string line.memo )
        ]


optionalEncodeString : String -> Encode.Value
optionalEncodeString value =
    if String.trim value == "" then
        Encode.null

    else
        Encode.string value


rpc : String -> Encode.Value -> Decoder a -> (Result Http.Error a -> msg) -> Cmd msg
rpc functionName body decoder toMsg =
    Http.post
        { url = "/rpc/" ++ functionName
        , body = Http.jsonBody body
        , expect = expectJsonDetailed toMsg decoder
        }


view : Model -> Html Msg
view model =
    Html.div [ Attr.class "app-shell" ]
        [ viewNavigation model
        , Html.main_ [ Attr.class "page-shell" ] [ viewPage model ]
        ]


viewNavigation : Model -> Html Msg
viewNavigation model =
    Html.header [ Attr.class "topbar" ]
        [ Html.div [ Attr.class "brand" ] [ Html.h1 [] [ Html.text "Plutus" ] ]
        , selectControl model.loading "Book" (Maybe.withDefault "" model.selectedBook) SelectBook
            (( "", "Select book" ) :: List.map (\book -> ( book.id, book.name )) model.books ++ [ ( addBookValue, "Add book…" ) ])
        , selectControl model.loading "Account" (Maybe.withDefault "" model.selectedAccount) SelectAccount
            (( "", "Select account" ) :: List.map (\account -> ( account.id, account.id )) model.accounts ++ [ ( addAccountValue, "Add account…" ) ])
        , selectControl model.loading "Report" (reportIdForPage model.page) SelectReport
            (List.map (\report -> ( report.id, report.name )) model.reportOptions)
        , Html.div [ Attr.class "status-line" ]
            [ Html.span [ Attr.classList [ ( "busy", model.loading ) ] ] [ Html.text model.status ] ]
        ]


selectControl : Bool -> String -> String -> (String -> Msg) -> List ( String, String ) -> Html Msg
selectControl disabled label current toMsg options =
    Html.label [ Attr.class "nav-field" ]
        [ Html.span [] [ Html.text label ]
        , Html.select [ Attr.value current, Attr.disabled disabled, Events.onInput toMsg ]
            (List.map
                (\( value, text ) ->
                    Html.option [ Attr.value value, Attr.selected (value == current) ] [ Html.text text ]
                )
                options
            )
        ]


reportIdForPage : Page -> String
reportIdForPage page =
    case page of
        GeneralJournalPage -> "general-journal"
        BalanceSheetPage -> "balance-sheet"
        TrialBalancePage -> "trial-balance"
        ProfitLossPage -> "profit-loss"
        CashFlowPage -> "cash-flow"
        _ -> "ledger"


viewPage : Model -> Html Msg
viewPage model =
    if model.loading then
        Html.section [ Attr.class "panel loading-panel" ]
            [ Html.text model.status ]

    else
        viewReadyPage model


viewReadyPage : Model -> Html Msg
viewReadyPage model =
    case model.page of
        LedgerPage -> viewLedger model
        GeneralJournalPage -> viewJournal model
        BalanceSheetPage -> viewReport "Balance Sheet" False model
        TrialBalancePage -> viewTrialBalance model
        ProfitLossPage -> viewReport "Income and Expenses" True model
        CashFlowPage -> viewReport "Cash Flow" True model
        AddBookPage -> viewAddBook model
        AddAccountPage -> viewAddAccount model
        ShellPage ->
            Html.section [ Attr.class "panel narrow-page" ]
                [ sectionHeader "Start accounting" (Html.text "")
                , Html.p [] [ Html.text "Create a book to begin." ]
                , Html.button [ Attr.type_ "button", Events.onClick (SelectBook addBookValue) ] [ Html.text "Add book" ]
                ]


viewLedger : Model -> Html Msg
viewLedger model =
    Html.div [ Attr.class "ledger-page" ]
        [ Html.section [ Attr.class "panel ledger-panel" ]
            [ sectionHeader "Account ledger" (Html.button [ Attr.type_ "button", Events.onClick NewTransaction ] [ Html.text "New transaction" ])
            , viewValidationMessages model.pageValidation
            , Html.table [ Attr.class "ledger-table ledger-register" ]
                [ Html.thead []
                    [ Html.tr []
                        [ Html.th [ Attr.class "ledger-date" ] [ Html.text "Date" ]
                        , Html.th [ Attr.class "ledger-xid" ] [ Html.text "XID" ]
                        , Html.th [ Attr.class "ledger-description" ] [ Html.text "Description" ]
                        , Html.th [ Attr.class "ledger-transfer" ] [ Html.text "Transfer" ]
                        , Html.th [ Attr.class "ledger-reconciled" ] [ Html.text "R" ]
                        , Html.th [ Attr.class "number ledger-amount" ] [ Html.text "Amount" ]
                        , Html.th [ Attr.class "number ledger-balance" ] [ Html.text "Balance" ]
                        , Html.th [ Attr.class "ledger-actions" ] [ Html.text "Actions" ]
                        ]
                    ]
                , Html.tbody [] (List.concatMap (viewLedgerEntry model) model.ledger)
                ]
            ]
        , viewLedgerEdit model
        , viewTransactionEditor model
        ]


viewLedgerEntry : Model -> LedgerEntry -> List (Html Msg)
viewLedgerEntry model entry =
    let
        expanded =
            List.member entry.xid model.expandedTransactions

        selected =
            model.transactionXid == Just entry.xid
                || (model.ledgerEdit |> Maybe.map .xid) == Just entry.xid

        mainRow =
            Html.tr
                [ Attr.classList
                    [ ( "ledger-line", True )
                    , ( "ledger-line-green", modBy 2 entry.xid == 0 )
                    , ( "ledger-line-yellow", modBy 2 entry.xid /= 0 )
                    , ( "ledger-row-unresolved", not entry.reconciled )
                    , ( "ledger-row-selected", selected )
                    ]
                ]
                [ Html.td [ Attr.class "ledger-date" ] [ Html.text entry.date ]
                , Html.td [ Attr.class "ledger-xid" ] [ Html.text (String.fromInt entry.xid) ]
                , Html.td [ Attr.class "ledger-description" ] [ Html.text (Maybe.withDefault "" entry.description) ]
                , Html.td [ Attr.class "ledger-transfer" ] [ Html.text (Maybe.withDefault (if entry.split then "Split" else "") entry.transfer) ]
                , Html.td [ Attr.class "ledger-reconciled" ]
                    [ Html.span
                        [ Attr.classList
                            [ ( "status-badge", True )
                            , ( "status-resolved", entry.reconciled )
                            , ( "status-unresolved", not entry.reconciled )
                            ]
                        , Attr.title (if entry.reconciled then "Resolved" else "Unresolved")
                        ]
                        [ Html.text (if entry.reconciled then "R" else "U") ]
                    ]
                , Html.td [ Attr.class "number ledger-amount" ] [ Html.text (money entry.amount) ]
                , Html.td [ Attr.class "number ledger-balance" ] [ Html.text (money entry.balance) ]
                , Html.td [ Attr.class "row-action" ]
                    [ Html.button [ Attr.type_ "button", Events.onClick (BeginLedgerEdit entry) ] [ Html.text "Line" ]
                    , Html.button [ Attr.type_ "button", Events.onClick (EditTransaction entry) ] [ Html.text "Transaction" ]
                    , Html.button [ Attr.type_ "button", Events.onClick (ToggleTransaction entry.xid) ] [ Html.text (if expanded then "Hide" else "Details") ]
                    ]
                ]

        detailRows =
            if expanded then
                List.map viewTransactionLine entry.lines

            else
                []
    in
    mainRow :: detailRows


viewTransactionLine : TransactionLine -> Html Msg
viewTransactionLine line =
    Html.tr [ Attr.class "ledger-split-line" ]
        [ Html.td [ Attr.class "ledger-date split-empty-date" ] []
        , Html.td [ Attr.class "ledger-xid" ] []
        , Html.td [ Attr.class "ledger-description" ] [ Html.text (Maybe.withDefault "" line.comment) ]
        , Html.td [ Attr.class "ledger-transfer" ] [ Html.text line.account ]
        , Html.td [ Attr.class "ledger-reconciled" ] []
        , Html.td [ Attr.class "number ledger-amount" ] [ Html.text (money line.amount) ]
        , Html.td [ Attr.class "number ledger-balance" ] []
        , Html.td [ Attr.class "ledger-actions" ] []
        ]


viewLedgerEdit : Model -> Html Msg
viewLedgerEdit model =
    case model.ledgerEdit of
        Nothing ->
            Html.text ""

        Just edit ->
            Html.section [ Attr.class "panel narrow-page ledger-edit-panel" ]
                [ sectionHeader ("Edit ledger line " ++ String.fromInt edit.xid) (Html.text "")
                , Html.div [ Attr.class "form" ]
                    [ inputField "Date" "date" edit.date UpdateLedgerEditDate
                    , inputField "Description" "text" edit.description UpdateLedgerEditDescription
                    , Html.button [ Attr.type_ "button", Attr.class "primary-action", Events.onClick SaveLedgerEdit ] [ Html.text "Save line" ]
                    ]
                ]


viewTransactionEditor : Model -> Html Msg
viewTransactionEditor model =
    Html.section
        [ Attr.classList
            [ ( "panel", True )
            , ( "transaction-editor", True )
            , ( "transaction-editor-active", model.transactionXid /= Nothing )
            ]
        ]
        [ sectionHeader
            (case model.transactionXid of
                Just xid -> "Edit transaction " ++ String.fromInt xid
                Nothing -> "New transaction"
            )
            (Html.text "")
        , Html.div [ Attr.class "form transaction-header" ]
            [ inputField "Date" "date" model.transactionDate UpdateTransactionDate
            , inputField "Description" "text" model.transactionComment UpdateTransactionComment
            , Html.label [ Attr.class "checkbox-field" ]
                [ Html.input [ Attr.type_ "checkbox", Attr.checked model.transactionResolved, Events.onCheck UpdateTransactionResolved ] []
                , Html.span [] [ Html.text "Resolved" ]
                ]
            ]
        , Html.table [ Attr.class "data-table transaction-lines" ]
            [ Html.thead [] [ Html.tr [] [ Html.th [] [ Html.text "Account" ], Html.th [] [ Html.text "Signed amount" ], Html.th [] [ Html.text "Memo" ], Html.th [] [] ] ]
            , Html.tbody [] (List.map (viewDraftLine model.accounts) model.draftLines)
            ]
        , Html.div [ Attr.class "form-actions" ]
            [ Html.button [ Attr.type_ "button", Events.onClick AddDraftLine ] [ Html.text "Add line" ]
            , Html.button [ Attr.type_ "button", Events.onClick PreviewTransaction ] [ Html.text "Preview" ]
            , Html.button [ Attr.type_ "button", Attr.class "primary-action", Events.onClick SubmitTransaction ] [ Html.text "Save transaction" ]
            ]
        , viewPreview model.preview
        ]


viewDraftLine : List Account -> DraftLine -> Html Msg
viewDraftLine accounts line =
    Html.tr [ Attr.class "transaction-draft-row" ]
        [ Html.td []
            [ Html.select [ Attr.value line.account, Events.onInput (UpdateDraftAccount line.key) ]
                (Html.option [ Attr.value "", Attr.selected (line.account == "") ] [ Html.text "Select account" ]
                    :: List.map
                        (\account ->
                            Html.option
                                [ Attr.value account.id, Attr.selected (account.id == line.account) ]
                                [ Html.text (account.id ++ " (" ++ account.asset ++ ")") ]
                        )
                        accounts
                )
            ]
        , Html.td [] [ Html.input [ Attr.type_ "text", Attr.attribute "inputmode" "decimal", Attr.value line.amount, Events.onInput (UpdateDraftAmount line.key) ] [] ]
        , Html.td [] [ Html.input [ Attr.type_ "text", Attr.value line.memo, Events.onInput (UpdateDraftMemo line.key) ] [] ]
        , Html.td [] [ Html.button [ Attr.type_ "button", Events.onClick (RemoveDraftLine line.key) ] [ Html.text "Remove" ] ]
        ]


viewPreview : Maybe Preview -> Html Msg
viewPreview preview =
    case preview of
        Nothing ->
            Html.text ""

        Just value ->
            Html.div [ Attr.classList [ ( "preview", True ), ( "preview-valid", value.valid ), ( "preview-invalid", not value.valid ) ] ]
                [ Html.strong [] [ Html.text (if value.valid then "Valid transaction" else "Invalid transaction") ]
                , Html.span []
                    [ Html.text
                        (case ( value.errorCode, value.errorMessage ) of
                            ( Just code, Just message ) -> code ++ ": " ++ message
                            ( _, Just message ) -> message
                            _ -> ""
                        )
                    ]
                , Html.ul []
                    (Dict.toList value.imbalance
                        |> List.map (\( asset, amount ) -> Html.li [] [ Html.text (asset ++ ": " ++ money amount) ])
                    )
                , viewNormalizedTransaction value.normalizedTransaction
                ]


viewNormalizedTransaction : Maybe NormalizedTransaction -> Html Msg
viewNormalizedTransaction normalized =
    case normalized of
        Nothing ->
            Html.text ""

        Just transaction ->
            Html.div [ Attr.class "normalized-transaction" ]
                [ Html.span []
                    [ Html.text
                        ("Normalized: "
                            ++ transaction.date
                            ++ " — "
                            ++ Maybe.withDefault "(no description)" transaction.comment
                        )
                    ]
                , Html.ul []
                    (List.map
                        (\line ->
                            Html.li []
                                [ Html.text (normalizedLineText line) ]
                        )
                        transaction.lines
                    )
                ]


normalizedLineText : TransactionLine -> String
normalizedLineText line =
    line.account
        ++ ": "
        ++ money line.amount
        ++ (case line.comment of
                Just memo -> " — " ++ memo
                Nothing -> ""
           )


viewJournal : Model -> Html Msg
viewJournal model =
    Html.section [ Attr.class "panel journal-panel" ]
        [ sectionHeader "General Journal" (Html.text "")
        , viewValidationMessages model.pageValidation
        , Html.table [ Attr.class "data-table general-journal-table" ]
            [ Html.thead [] [ Html.tr [] [ Html.th [ Attr.class "journal-date" ] [ Html.text "Date" ], Html.th [ Attr.class "journal-xid" ] [ Html.text "XID" ], Html.th [ Attr.class "journal-description" ] [ Html.text "Description" ], Html.th [ Attr.class "journal-reconciled" ] [ Html.text "R" ], Html.th [ Attr.class "journal-account" ] [ Html.text "Account" ], Html.th [ Attr.class "journal-memo" ] [ Html.text "Memo" ], Html.th [ Attr.class "number journal-debit" ] [ Html.text "Debit" ], Html.th [ Attr.class "number journal-credit" ] [ Html.text "Credit" ] ] ]
            , Html.tbody [] (List.map viewJournalRow model.journal)
            ]
        ]


viewJournalRow : JournalRow -> Html Msg
viewJournalRow row =
    Html.tr
        [ Attr.classList
            [ ( "journal-group-even", modBy 2 row.xid == 0 )
            , ( "journal-group-odd", modBy 2 row.xid /= 0 )
            , ( "journal-first-line", row.lineOrder == 1 )
            , ( "journal-unresolved", not row.reconciled )
            ]
        ]
        [ Html.td [ Attr.class "journal-date" ] [ Html.text (if row.lineOrder == 1 then row.date else "") ]
        , Html.td [ Attr.class "journal-xid" ] [ Html.text (if row.lineOrder == 1 then String.fromInt row.xid else "") ]
        , Html.td [ Attr.class "journal-description" ] [ Html.text (if row.lineOrder == 1 then Maybe.withDefault "" row.description else "") ]
        , Html.td [ Attr.class "journal-reconciled" ] [ Html.text (if row.lineOrder == 1 then (if row.reconciled then "R" else "U") else "") ]
        , Html.td [ Attr.classList [ ( "journal-account", True ), ( "journal-credit-account", row.credit /= Nothing ) ] ] [ Html.text row.account ]
        , Html.td [ Attr.class "journal-memo" ] [ Html.text (Maybe.withDefault "" row.memo) ]
        , Html.td [ Attr.class "number journal-debit" ] [ Html.text (maybeMoney row.debit) ]
        , Html.td [ Attr.class "number journal-credit" ] [ Html.text (maybeMoney row.credit) ]
        ]


viewReport : String -> Bool -> Model -> Html Msg
viewReport title period model =
    Html.section [ Attr.class "panel" ]
        [ sectionHeader title (Html.text "")
        , if period then viewPeriodToolbar model else viewAsOfToolbar model
        , viewValidationMessages model.pageValidation
        , Html.table [ Attr.class "data-table report-table" ]
            [ Html.thead [] [ Html.tr [] [ Html.th [] [ Html.text "Section" ], Html.th [] [ Html.text "Account" ], Html.th [] [ Html.text "Asset" ], Html.th [ Attr.class "number" ] [ Html.text "Pretax" ], Html.th [ Attr.class "number" ] [ Html.text "Posttax" ] ] ]
            , Html.tbody [] (List.map viewReportRow model.reportRows)
            ]
        ]


viewReportRow : ReportRow -> Html Msg
viewReportRow row =
    Html.tr [ reportRowClasses row.rowKind ]
        [ Html.td [ Attr.class "report-section" ] [ Html.text row.section ]
        , Html.td [ Attr.class "report-account" ] [ Html.text row.account ]
        , Html.td [ Attr.class "report-asset" ] [ Html.text (Maybe.withDefault "" row.originalCurrency) ]
        , Html.td [ Attr.class "number report-pretax" ] [ Html.text (maybeMoney row.pretax) ]
        , Html.td [ Attr.class "number report-posttax" ] [ Html.text (maybeMoney row.posttax) ]
        ]


viewTrialBalance : Model -> Html Msg
viewTrialBalance model =
    Html.section [ Attr.class "panel" ]
        [ sectionHeader "Trial Balance" (Html.text "")
        , viewAsOfToolbar model
        , viewValidationMessages model.pageValidation
        , Html.table [ Attr.class "data-table report-table trial-balance-table" ]
            [ Html.thead [] [ Html.tr [] [ Html.th [] [ Html.text "Account" ], Html.th [] [ Html.text "Asset" ], Html.th [ Attr.class "number" ] [ Html.text "Debit" ], Html.th [ Attr.class "number" ] [ Html.text "Credit" ] ] ]
            , Html.tbody [] (List.map viewTrialRow model.trialRows)
            ]
        ]


viewValidationMessages : List String -> Html Msg
viewValidationMessages messages =
    if List.isEmpty messages then
        Html.text ""

    else
        Html.div [ Attr.class "validation-message" ]
            (List.map (\message -> Html.p [] [ Html.text message ]) messages)


viewTrialRow : TrialRow -> Html Msg
viewTrialRow row =
    Html.tr [ reportRowClasses row.rowKind ]
        [ Html.td [ Attr.class "report-account" ] [ Html.text row.account ]
        , Html.td [ Attr.class "report-asset" ] [ Html.text (Maybe.withDefault "" row.originalCurrency) ]
        , Html.td [ Attr.class "number report-debit" ] [ Html.text (maybeMoney row.debit) ]
        , Html.td [ Attr.class "number report-credit" ] [ Html.text (maybeMoney row.credit) ]
        ]


reportRowClasses : String -> Html.Attribute Msg
reportRowClasses rowKind =
    Attr.classList
        [ ( "report-row", True )
        , ( "report-account-row", rowKind == "account" )
        , ( "report-computed-row", rowKind == "computed" )
        , ( "report-section-total", rowKind == "section_total" || rowKind == "total" )
        , ( "report-grand-total", rowKind == "grand_total" )
        , ( "report-difference-row", rowKind == "difference" )
        , ( "report-total", rowKind /= "account" )
        ]


viewAsOfToolbar : Model -> Html Msg
viewAsOfToolbar model =
    Html.div [ Attr.class "report-toolbar" ]
        [ inputField "As of" "date" model.reportDate UpdateReportDate
        , Html.button [ Attr.type_ "button", Events.onClick RefreshReport ] [ Html.text "Refresh" ]
        ]


viewPeriodToolbar : Model -> Html Msg
viewPeriodToolbar model =
    Html.div [ Attr.class "report-toolbar period-report-toolbar" ]
        [ inputField "From" "date" model.reportFrom UpdateReportFrom
        , inputField "To" "date" model.reportTo UpdateReportTo
        , Html.button [ Attr.type_ "button", Events.onClick RefreshReport ] [ Html.text "Refresh" ]
        ]


viewAddBook : Model -> Html Msg
viewAddBook model =
    Html.section [ Attr.class "panel narrow-page form-page" ]
        [ sectionHeader "Add book" (Html.text "")
        , Html.form [ Attr.class "form", Events.onSubmit SubmitBook ]
            [ inputField "Identifier" "text" model.bookIdInput UpdateBookId
            , inputField "Name" "text" model.bookNameInput UpdateBookName
            , choiceField "Reporting asset" model.bookAssetInput UpdateBookAsset model.assets
            , Html.button [ Attr.type_ "submit" ] [ Html.text "Create book" ]
            ]
        ]


viewAddAccount : Model -> Html Msg
viewAddAccount model =
    Html.section [ Attr.class "panel narrow-page form-page" ]
        [ sectionHeader "Add account" (Html.text "")
        , viewValidationMessages model.pageValidation
        , Html.form [ Attr.class "form", Events.onSubmit SubmitAccount ]
            [ inputField "Name" "text" model.accountIdInput UpdateAccountId
            , choiceField "Type" model.accountTypeInput UpdateAccountType model.accountTypes
            , choiceField "Asset" model.accountAssetInput UpdateAccountAsset model.assets
            , inputField "Pretax fraction" "text" model.accountPretaxInput UpdateAccountPretax
            , inputField "Opening balance (optional)" "text" model.openingBalanceInput UpdateOpeningBalance
            , inputField "Opening date" "date" model.openingDateInput UpdateOpeningDate
            , Html.button [ Attr.type_ "submit" ] [ Html.text "Create account" ]
            ]
        ]


sectionHeader : String -> Html Msg -> Html Msg
sectionHeader title action =
    Html.div [ Attr.class "section-header" ] [ Html.h2 [] [ Html.text title ], action ]


inputField : String -> String -> String -> (String -> Msg) -> Html Msg
inputField label inputType value toMsg =
    Html.label [ Attr.class "field" ]
        [ Html.span [] [ Html.text label ]
        , Html.input [ Attr.type_ inputType, Attr.value value, Events.onInput toMsg ] []
        ]


choiceField : String -> String -> (String -> Msg) -> List String -> Html Msg
choiceField label current toMsg choices =
    Html.label [ Attr.class "field" ]
        [ Html.span [] [ Html.text label ]
        , Html.select [ Attr.value current, Events.onInput toMsg ]
            (List.map
                (\choice ->
                    Html.option [ Attr.value choice, Attr.selected (choice == current) ] [ Html.text choice ]
                )
                choices
            )
        ]


money : Float -> String
money value =
    String.fromFloat value


maybeMoney : Maybe Float -> String
maybeMoney value =
    Maybe.map money value |> Maybe.withDefault ""


addBookValue : String
addBookValue =
    "__add_book__"


addAccountValue : String
addAccountValue =
    "__add_account__"


componentListDecoder : Decoder (List Component)
componentListDecoder =
    Decode.list orderedComponentDecoder
        |> Decode.map
            (List.sortBy Tuple.first
                >> List.map Tuple.second
            )


orderedComponentDecoder : Decoder ( Int, Component )
orderedComponentDecoder =
    Decode.map2 Tuple.pair
        (Decode.field "row_order" Decode.int)
        componentDecoder


componentDecoder : Decoder Component
componentDecoder =
    Decode.field "component" Decode.string
        |> Decode.andThen
            (\component ->
                case component of
                    "book_option" -> Decode.map BookComponent (Decode.field "payload" bookDecoder)
                    "account_option" -> Decode.map AccountComponent (Decode.field "payload" accountDecoder)
                    "report_option" -> Decode.map ReportOptionComponent (Decode.field "payload" reportOptionDecoder)
                    "transfer_account_option" -> Decode.map TransferOptionComponent (Decode.at [ "payload", "id" ] Decode.string)
                    "ledger_row" -> Decode.map LedgerComponent (Decode.field "payload" ledgerDecoder)
                    "journal_row" -> Decode.map JournalComponent (Decode.field "payload" journalDecoder)
                    "report_row" -> Decode.map ReportComponent (Decode.field "payload" reportRowDecoder)
                    "trial_balance_row" -> Decode.map TrialComponent (Decode.field "payload" trialRowDecoder)
                    "asset_option" -> Decode.map AssetComponent (Decode.at [ "payload", "id" ] Decode.string)
                    "account_type_option" -> Decode.map AccountTypeComponent (Decode.at [ "payload", "id" ] Decode.string)
                    "page_context" -> Decode.map PageContextComponent (Decode.field "payload" pageContextDecoder)
                    _ -> Decode.succeed OtherComponent
            )


bookDecoder : Decoder Book
bookDecoder =
    Decode.map4 Book
        (Decode.field "id" Decode.string)
        (Decode.field "name" Decode.string)
        (Decode.field "reporting_asset" Decode.string)
        (optionalField "selected" Decode.bool False)


accountDecoder : Decoder Account
accountDecoder =
    Decode.map5 Account
        (Decode.field "book_id" Decode.string)
        (Decode.field "id" Decode.string)
        (Decode.field "type" Decode.string)
        (Decode.field "asset" Decode.string)
        (Decode.field "pretax" Decode.float)


reportOptionDecoder : Decoder ReportOption
reportOptionDecoder =
    Decode.map2 ReportOption
        (Decode.field "id" Decode.string)
        (Decode.field "name" Decode.string)


transactionLineDecoder : Decoder TransactionLine
transactionLineDecoder =
    Decode.map3 TransactionLine
        (Decode.field "account" Decode.string)
        (maybeField "comment" Decode.string)
        (Decode.field "amount" Decode.float)


ledgerDecoder : Decoder LedgerEntry
ledgerDecoder =
    Decode.succeed LedgerEntry
        |> andMap (Decode.field "date" Decode.string)
        |> andMap (Decode.field "xid" Decode.int)
        |> andMap (Decode.field "account" Decode.string)
        |> andMap (maybeField "description" Decode.string)
        |> andMap (maybeField "transaction_comment" Decode.string)
        |> andMap (maybeField "transfer" Decode.string)
        |> andMap (Decode.field "reconciled" Decode.bool)
        |> andMap (Decode.field "amount" Decode.float)
        |> andMap (Decode.field "balance" Decode.float)
        |> andMap (Decode.field "split" Decode.bool)
        |> andMap (Decode.field "split_lines" (Decode.list transactionLineDecoder))


journalDecoder : Decoder JournalRow
journalDecoder =
    Decode.succeed JournalRow
        |> andMap (Decode.field "date" Decode.string)
        |> andMap (Decode.field "xid" Decode.int)
        |> andMap (maybeField "description" Decode.string)
        |> andMap (Decode.field "reconciled" Decode.bool)
        |> andMap (Decode.field "line_order" Decode.int)
        |> andMap (Decode.field "account" Decode.string)
        |> andMap (maybeField "memo" Decode.string)
        |> andMap (maybeField "debit" Decode.float)
        |> andMap (maybeField "credit" Decode.float)


reportRowDecoder : Decoder ReportRow
reportRowDecoder =
    Decode.succeed ReportRow
        |> andMap (Decode.field "section" Decode.string)
        |> andMap (Decode.field "row_kind" Decode.string)
        |> andMap (Decode.field "account" Decode.string)
        |> andMap (maybeField "origcurrency" Decode.string)
        |> andMap (maybeField "pretax" Decode.float)
        |> andMap (maybeField "posttax" Decode.float)


trialRowDecoder : Decoder TrialRow
trialRowDecoder =
    Decode.succeed TrialRow
        |> andMap (Decode.field "row_kind" Decode.string)
        |> andMap (Decode.field "account" Decode.string)
        |> andMap (maybeField "origcurrency" Decode.string)
        |> andMap (maybeField "debit" Decode.float)
        |> andMap (maybeField "credit" Decode.float)


previewDecoder : Decoder Preview
previewDecoder =
    Decode.map5 Preview
        (Decode.field "valid" Decode.bool)
        (maybeField "error_code" Decode.string)
        (maybeField "error_message" Decode.string)
        (Decode.field "imbalance" (Decode.dict Decode.float))
        (maybeField "normalized_transaction" normalizedTransactionDecoder)


normalizedTransactionDecoder : Decoder NormalizedTransaction
normalizedTransactionDecoder =
    Decode.map4 NormalizedTransaction
        (Decode.field "date" Decode.string)
        (Decode.field "resolved" Decode.bool)
        (maybeField "comment" Decode.string)
        (Decode.field "lines" (Decode.list transactionLineDecoder))


pageContextDecoder : Decoder PageContext
pageContextDecoder =
    Decode.succeed PageContext
        |> andMap (Decode.field "page" Decode.string)
        |> andMap (maybeField "as_of" Decode.string)
        |> andMap (maybeField "from" Decode.string)
        |> andMap (maybeField "to" Decode.string)
        |> andMap (maybeField "reporting_asset" Decode.string)
        |> andMap (maybeField "account_type" Decode.string)
        |> andMap (maybeField "asset" Decode.string)
        |> andMap (maybeField "pretax" Decode.float)
        |> andMap (maybeField "opening_date" Decode.string)
        |> andMap (optionalField "validation_messages" (Decode.list Decode.string) [])


mutationResultDecoder : Decoder MutationResult
mutationResultDecoder =
    Decode.map3 MutationResult
        (Decode.field "book_id" Decode.string)
        (Decode.field "xid" Decode.int)
        (Decode.field "resolved" Decode.bool)


ledgerEditDecoder : Decoder LedgerEdit
ledgerEditDecoder =
    Decode.map4 LedgerEdit
        (Decode.field "xid" Decode.int)
        (Decode.field "account_id" Decode.string)
        (Decode.succeed "")
        (Decode.succeed "")


andMap : Decoder a -> Decoder (a -> b) -> Decoder b
andMap valueDecoder functionDecoder =
    Decode.map2 (|>) valueDecoder functionDecoder


maybeField : String -> Decoder a -> Decoder (Maybe a)
maybeField field decoder =
    Decode.oneOf
        [ Decode.field field (Decode.nullable decoder)
        , Decode.succeed Nothing
        ]


optionalField : String -> Decoder a -> a -> Decoder a
optionalField field decoder fallback =
    Decode.oneOf [ Decode.field field decoder, Decode.succeed fallback ]


expectJsonDetailed : (Result Http.Error a -> msg) -> Decoder a -> Http.Expect msg
expectJsonDetailed toMsg decoder =
    Http.expectStringResponse toMsg <|
        \response ->
            case response of
                Http.BadUrl_ url -> Err (Http.BadUrl url)
                Http.Timeout_ -> Err Http.Timeout
                Http.NetworkError_ -> Err Http.NetworkError
                Http.BadStatus_ metadata body -> Err (Http.BadBody (databaseError metadata.statusCode body))
                Http.GoodStatus_ _ body ->
                    Decode.decodeString decoder body
                        |> Result.mapError (Decode.errorToString >> Http.BadBody)


databaseError : Int -> String -> String
databaseError status body =
    case Decode.decodeString databaseErrorDecoder body of
        Ok ( message, details ) ->
            let
                suffix =
                    case details of
                        Just code -> " (" ++ code ++ ")"
                        Nothing -> ""
            in
            "HTTP " ++ String.fromInt status ++ ": " ++ message ++ suffix

        Err _ -> "HTTP " ++ String.fromInt status ++ ": " ++ String.trim body


databaseErrorDecoder : Decoder ( String, Maybe String )
databaseErrorDecoder =
    Decode.map2 Tuple.pair
        (Decode.field "message" Decode.string)
        (maybeField "details" Decode.string)


errorToString : Http.Error -> String
errorToString err =
    case err of
        Http.BadUrl url -> "Bad URL: " ++ url
        Http.Timeout -> "The request timed out"
        Http.NetworkError -> "Cannot reach the local server"
        Http.BadStatus status -> "HTTP error " ++ String.fromInt status
        Http.BadBody reason -> reason
