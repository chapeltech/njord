port module Main exposing (main)

import Browser
import Browser.Dom
import Browser.Navigation as Nav
import Dict exposing (Dict)
import Html exposing (Html)
import Html.Attributes as Attr
import Html.Events as Events
import Html.Keyed as Keyed
import Http
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import String
import Task
import Url exposing (Url)


port saveLanguage : String -> Cmd msg


port languageChanged : (String -> msg) -> Sub msg


type alias Flags =
    { language : String }


main : Program Flags Model Msg
main =
    Browser.application
        { init = init
        , update = update
        , subscriptions = \_ -> languageChanged LanguageChanged
        , view = view
        , onUrlRequest = LinkClicked
        , onUrlChange = UrlChanged
        }


init : Flags -> Url -> Nav.Key -> ( Model, Cmd Msg )
init flags url key =
    let
        route =
            routeFromUrl url

        model =
            { initialModel
                | navigationKey = Just key
                , currentUrl = Url.toString url
                , selectedBook = route.book
                , selectedAccount = route.account
                , selectedReport = route.report
                , language = flags.language
            }
    in
    -- The cluster catalogue is a separate control database. Always load its
    -- shell first, including for a direct book URL, then load the page from
    -- the selected book database. This also makes new-tab routes complete.
    startPageRequest (loadShellFor flags.language route.book)
        { model | page = route.page, pendingRoute = Just route }


type Page
    = ShellPage
    | AdminPage
    | BookPage
    | AccountsPage
    | LedgerPage
    | ReportsPage
    | ReportPage
    | GeneralJournalPage
    | ReconciliationPage
    | AddBookPage
    | AddAccountPage


type alias Book =
    { id : String
    , name : String
    , reportingAsset : String
    , accessLevel : String
    , selected : Bool
    }


type alias LanguageOption =
    { locale : String
    , flag : String
    , label : String
    }


type alias Account =
    { bookId : String
    , id : String
    , asset : String
    }


type alias AccountSummary =
    { bookId : String
    , id : String
    , name : String
    , accountType : String
    , asset : String
    , parentId : Maybe String
    , depth : Int
    , ancestorIds : List String
    , path : String
    , hasChildren : Bool
    , placeholder : Bool
    , accountKind : String
    , balance : String
    , subtreeBalance : String
    , subtreeBalanceComplete : Bool
    , reportingValue : Maybe String
    , reportingAsset : Maybe String
    , postingCount : Int
    , unreconciledCount : Int
    , isCashAccount : Bool
    }


type alias ParentAccountOption =
    { id : String
    , name : String
    , path : String
    , accountType : String
    , asset : String
    , placeholder : Bool
    }


type alias AccountKindOption =
    { id : String
    , label : String
    , requiredType : Maybe String
    }


type alias BookIdentity =
    { id : String
    , name : String
    , reportingAsset : String
    , entityType : String
    , entityTypeLabel : String
    , archivedAt : Maybe String
    }


type alias BookAccess =
    { principalId : String
    , databaseRole : String
    , displayName : String
    , githubLogin : Maybe String
    , accessLevel : String
    , status : String
    , currentUser : Bool
    }


type alias GlobalUser =
    { principalId : String
    , databaseRole : String
    , displayName : String
    , githubLogin : Maybe String
    , status : String
    , bookCount : Int
    , globalAdmin : Bool
    , currentUser : Bool
    , enabled : Bool
    , canChangeEnabled : Bool
    , actionKey : String
    , actionLabel : String
    }


type alias ReportingCurrency =
    { effectiveFrom : String
    , asset : String
    , current : Bool
    }


type alias CompanyProfile =
    { enabled : Bool
    , legalName : String
    , companyNumber : Maybe String
    , legalForm : String
    , accountingFramework : String
    , utr : Maybe String
    , vatRegistrationNumber : Maybe String
    , vatScheme : String
    , registeredOffice : Maybe String
    , incorporatedOn : Maybe String
    , notes : Maybe String
    }


type alias PanamaBusinessProfile =
    { enabled : Bool
    , legalName : String
    , ruc : String
    , verificationDigit : Maybe String
    , legalForm : String
    , municipality : String
    , incorporatedOn : Maybe String
    , residentAgent : Maybe String
    , registeredAddress : Maybe String
    , operationsNoticeNumber : Maybe String
    , itbmsRegistered : Bool
    , conductsLodgingActivity : Bool
    , residentialPropertyEnabled : Bool
    , propertyCount : Int
    , notes : Maybe String
    }


type alias PanamaFiscalPeriod =
    { id : String
    , periodStart : String
    , periodEnd : String
    , status : String
    , incomeTaxReturnDueOn : Maybe String
    , municipalReturnDueOn : Maybe String
    , notes : Maybe String
    }


type alias TaiwanBusinessProfile =
    { enabled : Bool
    , legalName : String
    , unifiedBusinessNumber : String
    , legalForm : String
    , businessTaxFrequency : String
    , usesUniformInvoices : Bool
    , establishedOn : Maybe String
    , responsiblePerson : Maybe String
    , registeredAddress : Maybe String
    , taxRegistrationNotes : Maybe String
    , manufacturingEnabled : Bool
    , inventoryItemCount : Int
    , notes : Maybe String
    }


type alias TaiwanFiscalPeriod =
    { id : String
    , periodStart : String
    , periodEnd : String
    , status : String
    , annualIncomeTaxDueOn : Maybe String
    , provisionalIncomeTaxDueOn : Maybe String
    , undistributedEarningsDueOn : Maybe String
    , notes : Maybe String
    }


type alias NamedOption =
    { id : String
    , label : String
    }


type alias AccountingPeriod =
    { id : String
    , periodStart : String
    , periodEnd : String
    , status : String
    , accountsDueOn : Maybe String
    , corporationTaxDueOn : Maybe String
    , accountsFiledOn : Maybe String
    , ct600FiledOn : Maybe String
    , notes : Maybe String
    }


type alias VatControlAccountOption =
    { id : String
    , name : String
    , path : String
    , selected : Bool
    }


type alias ConfigurationCheck =
    { id : String
    , label : String
    , complete : Bool
    , message : String
    }


type alias Route =
    { page : Page
    , book : Maybe String
    , account : Maybe String
    , report : Maybe String
    }


type alias ReportOption =
    { id : String
    , name : String
    , description : String
    , group : String
    }


type alias ReportDefinition =
    { id : String
    , title : String
    , description : String
    , parameterKind : String
    , reportingAsset : String
    }


type alias ReportColumn =
    { id : String
    , label : String
    , alignment : String
    , valueFormat : String
    , treeColumn : Bool
    }


type alias GenericReportCell =
    { columnId : String
    , text : Maybe String
    , exact : Maybe String
    , suffix : Maybe String
    }


type alias GenericReportRow =
    { rowKind : String
    , depth : Int
    , accountId : Maybe String
    , cells : List GenericReportCell
    }


type alias BarChartDefinition =
    { id : String
    , title : String
    , valueLabel : String
    , valueFormat : String
    }


type alias BarChartPoint =
    { chartId : String
    , label : String
    , value : Maybe Float
    , exact : Maybe String
    , suffix : Maybe String
    }


type alias TransactionLine =
    { account : String
    , comment : Maybe String
    , amount : String
    }


type alias LedgerEntry =
    { date : String
    , xid : Int
    , account : String
    , description : Maybe String
    , transactionComment : Maybe String
    , transfer : Maybe String
    , amount : String
    , balance : String
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
    , debit : Maybe String
    , credit : Maybe String
    }


type alias ReconciliationEntry =
    { date : String
    , xid : Int
    , account : String
    , description : Maybe String
    , asset : String
    , amount : String
    , reconciled : Bool
    }


type alias PostingReconciliation =
    { bookId : String
    , xid : Int
    , account : String
    , reconciled : Bool
    }


type alias DraftLine =
    { key : Int
    , account : String
    , amount : String
    , memo : String
    }


type RegisterField
    = TransactionDateField
    | TransactionCommentField
    | DraftAccountField Int
    | DraftAmountField Int
    | DraftMemoField Int


type alias FieldSnapshot =
    { field : RegisterField
    , value : String
    , dirtyBefore : Bool
    , draftExistedBefore : Bool
    , draftAmountBefore : Maybe String
    , draftBalanceBefore : Maybe DraftBalance
    }


type alias DraftBalance =
    { asset : String
    , amount : String
    }


type UiStatus
    = StatusIdle
    | StatusKey String
    | StatusTemplate String (List ( String, String ))
    | StatusText String


type BookLifecycleAction
    = ArchiveLifecycle
    | RestoreLifecycle
    | DeleteLifecycle


type LedgerDestination
    = FinishLedgerTransaction
    | OpenLedgerTransaction Int
    | OpenLedgerAppend


type LedgerSync
    = LedgerIdle
    | LedgerSaving LedgerDestination
    | LedgerRefreshing LedgerDestination


type alias PageContext =
    { page : String
    , bookId : Maybe String
    , bookExists : Bool
    , configurationStatus : String
    , asOf : Maybe String
    , fromDate : Maybe String
    , toDate : Maybe String
    , reportingAsset : Maybe String
    , accountType : Maybe String
    , asset : Maybe String
    , parentId : Maybe String
    , accountKind : Maybe String
    , placeholder : Bool
    , pretax : Maybe String
    , openingDate : Maybe String
    , validationMessages : List String
    }


type alias MutationResult =
    { bookId : String
    , xid : Int
    }


type Component
    = BookComponent Book
    | AdminContextComponent Bool
    | GlobalUserComponent GlobalUser
    | BookIdentityComponent BookIdentity
    | BookAccessComponent BookAccess
    | BookAccessLevelOptionComponent NamedOption
    | BookEntityTypeOptionComponent NamedOption
    | ReportingCurrencyComponent ReportingCurrency
    | CompanyProfileComponent CompanyProfile
    | LegalFormOptionComponent NamedOption
    | AccountingFrameworkOptionComponent NamedOption
    | VatSchemeOptionComponent NamedOption
    | PeriodStatusOptionComponent NamedOption
    | AccountingPeriodComponent AccountingPeriod
    | VatControlAccountOptionComponent VatControlAccountOption
    | ConfigurationCheckComponent ConfigurationCheck
    | PanamaBusinessProfileComponent PanamaBusinessProfile
    | PanamaLegalFormOptionComponent NamedOption
    | PanamaMunicipalityOptionComponent NamedOption
    | PanamaPeriodStatusOptionComponent NamedOption
    | PanamaFiscalPeriodComponent PanamaFiscalPeriod
    | TaiwanBusinessProfileComponent TaiwanBusinessProfile
    | TaiwanLegalFormOptionComponent NamedOption
    | TaiwanTaxFrequencyOptionComponent NamedOption
    | TaiwanPeriodStatusOptionComponent NamedOption
    | TaiwanFiscalPeriodComponent TaiwanFiscalPeriod
    | AccountComponent Account
    | AccountSummaryComponent AccountSummary
    | ParentAccountOptionComponent ParentAccountOption
    | AccountKindOptionComponent AccountKindOption
    | ReportOptionComponent ReportOption
    | ReportDefinitionComponent ReportDefinition
    | ReportColumnComponent ReportColumn
    | GenericReportRowComponent GenericReportRow
    | BarChartDefinitionComponent BarChartDefinition
    | BarChartPointComponent BarChartPoint
    | LedgerComponent LedgerEntry
    | JournalComponent JournalRow
    | ReconciliationComponent ReconciliationEntry
    | AssetComponent String
    | AccountTypeComponent String
    | PageContextComponent PageContext
    | PresentationComponent String String
    | LanguageOptionComponent LanguageOption
    | OtherComponent


type alias Model =
    { page : Page
    , navigationKey : Maybe Nav.Key
    , currentUrl : String
    , pendingRoute : Maybe Route
    , books : List Book
    , globalAdmin : Bool
    , globalUsers : List GlobalUser
    , globalUserGithubInput : String
    , bookIdentity : Maybe BookIdentity
    , bookAccess : List BookAccess
    , bookAccessLevelOptions : List NamedOption
    , bookEntityTypeOptions : List NamedOption
    , reportingCurrencies : List ReportingCurrency
    , companyProfile : Maybe CompanyProfile
    , panamaBusinessProfile : Maybe PanamaBusinessProfile
    , taiwanBusinessProfile : Maybe TaiwanBusinessProfile
    , legalFormOptions : List NamedOption
    , accountingFrameworkOptions : List NamedOption
    , vatSchemeOptions : List NamedOption
    , periodStatusOptions : List NamedOption
    , accountingPeriods : List AccountingPeriod
    , vatControlAccountOptions : List VatControlAccountOption
    , configurationChecks : List ConfigurationCheck
    , panamaLegalFormOptions : List NamedOption
    , panamaMunicipalityOptions : List NamedOption
    , panamaPeriodStatusOptions : List NamedOption
    , panamaFiscalPeriods : List PanamaFiscalPeriod
    , taiwanLegalFormOptions : List NamedOption
    , taiwanTaxFrequencyOptions : List NamedOption
    , taiwanPeriodStatusOptions : List NamedOption
    , taiwanFiscalPeriods : List TaiwanFiscalPeriod
    , bookExists : Bool
    , bookConfigurationStatus : String
    , accounts : List Account
    , accountSummaries : List AccountSummary
    , parentAccountOptions : List ParentAccountOption
    , accountKindOptions : List AccountKindOption
    , collapsedAccounts : List String
    , reportOptions : List ReportOption
    , reportDefinition : Maybe ReportDefinition
    , reportColumns : List ReportColumn
    , genericReportRows : List GenericReportRow
    , barChartDefinitions : List BarChartDefinition
    , barChartPoints : List BarChartPoint
    , assets : List String
    , accountTypes : List String
    , selectedBook : Maybe String
    , selectedAccount : Maybe String
    , selectedReport : Maybe String
    , reconciliationAccount : Maybe String
    , ledger : List LedgerEntry
    , journal : List JournalRow
    , reconciliationRows : List ReconciliationEntry
    , reportDate : String
    , reportFrom : String
    , reportTo : String
    , bookIdInput : String
    , bookNameInput : String
    , bookAssetInput : String
    , bookEntityTypeInput : String
    , bookSettingsNameInput : String
    , bookSettingsEntityTypeInput : String
    , bookCurrencyInput : String
    , bookCurrencyEffectiveFromInput : String
    , bookDeleteConfirmationInput : String
    , bookAccessGithubInput : String
    , bookAccessLevelInput : String
    , companyLegalNameInput : String
    , companyNumberInput : String
    , companyLegalFormInput : String
    , companyFrameworkInput : String
    , companyUtrInput : String
    , companyVatRegistrationInput : String
    , companyVatSchemeInput : String
    , companyRegisteredOfficeInput : String
    , companyIncorporatedOnInput : String
    , companyNotesInput : String
    , companyPeriodIdInput : String
    , companyPeriodStartInput : String
    , companyPeriodEndInput : String
    , companyPeriodStatusInput : String
    , companyAccountsDueInput : String
    , companyCorporationTaxDueInput : String
    , companyAccountsFiledInput : String
    , companyCt600FiledInput : String
    , companyPeriodNotesInput : String
    , companyVatControlInput : String
    , panamaLegalNameInput : String
    , panamaRucInput : String
    , panamaVerificationDigitInput : String
    , panamaLegalFormInput : String
    , panamaMunicipalityInput : String
    , panamaIncorporatedOnInput : String
    , panamaResidentAgentInput : String
    , panamaRegisteredAddressInput : String
    , panamaOperationsNoticeInput : String
    , panamaItbmsRegisteredInput : Bool
    , panamaLodgingActivityInput : Bool
    , panamaPropertyEnabledInput : Bool
    , panamaNotesInput : String
    , panamaPeriodIdInput : String
    , panamaPeriodStartInput : String
    , panamaPeriodEndInput : String
    , panamaPeriodStatusInput : String
    , panamaIncomeTaxDueInput : String
    , panamaMunicipalDueInput : String
    , panamaPeriodNotesInput : String
    , taiwanLegalNameInput : String
    , taiwanUnifiedBusinessNumberInput : String
    , taiwanLegalFormInput : String
    , taiwanTaxFrequencyInput : String
    , taiwanUsesUniformInvoicesInput : Bool
    , taiwanEstablishedOnInput : String
    , taiwanResponsiblePersonInput : String
    , taiwanRegisteredAddressInput : String
    , taiwanTaxRegistrationNotesInput : String
    , taiwanManufacturingEnabledInput : Bool
    , taiwanNotesInput : String
    , taiwanPeriodIdInput : String
    , taiwanPeriodStartInput : String
    , taiwanPeriodEndInput : String
    , taiwanPeriodStatusInput : String
    , taiwanAnnualIncomeTaxDueInput : String
    , taiwanProvisionalIncomeTaxDueInput : String
    , taiwanUndistributedEarningsDueInput : String
    , taiwanPeriodNotesInput : String
    , accountIdInput : String
    , accountTypeInput : String
    , accountAssetInput : String
    , accountParentInput : String
    , accountKindInput : String
    , accountPlaceholderInput : Bool
    , accountPretaxInput : String
    , openingBalanceInput : String
    , openingDateInput : String
    , transactionXid : Maybe Int
    , transactionSimple : Bool
    , transactionPrimaryKey : Int
    , transactionDirty : Bool
    , committedTransactionXid : Maybe Int
    , ledgerSync : LedgerSync
    , transactionDate : String
    , transactionComment : String
    , draftLines : List DraftLine
    , nextDraftKey : Int
    , fieldSnapshot : Maybe FieldSnapshot
    , draftBalance : Maybe DraftBalance
    , nextDraftBalanceRequestId : Int
    , activeDraftBalanceRequestId : Maybe Int
    , pageValidation : List String
    , loading : Bool
    , navigationLocked : Bool
    , nextPageRequestId : Int
    , activePageRequestId : Maybe Int
    , status : UiStatus
    , presentation : Dict String String
    , language : String
    , pendingLanguage : Maybe String
    , languageOptions : List LanguageOption
    , languageMenuOpen : Bool
    }


initialModel : Model
initialModel =
    { page = ShellPage
    , navigationKey = Nothing
    , currentUrl = "/"
    , pendingRoute = Nothing
    , books = []
    , globalAdmin = False
    , globalUsers = []
    , globalUserGithubInput = ""
    , bookIdentity = Nothing
    , bookAccess = []
    , bookAccessLevelOptions = []
    , bookEntityTypeOptions = []
    , reportingCurrencies = []
    , companyProfile = Nothing
    , panamaBusinessProfile = Nothing
    , taiwanBusinessProfile = Nothing
    , legalFormOptions = []
    , accountingFrameworkOptions = []
    , vatSchemeOptions = []
    , periodStatusOptions = []
    , accountingPeriods = []
    , vatControlAccountOptions = []
    , configurationChecks = []
    , panamaLegalFormOptions = []
    , panamaMunicipalityOptions = []
    , panamaPeriodStatusOptions = []
    , panamaFiscalPeriods = []
    , taiwanLegalFormOptions = []
    , taiwanTaxFrequencyOptions = []
    , taiwanPeriodStatusOptions = []
    , taiwanFiscalPeriods = []
    , bookExists = False
    , bookConfigurationStatus = "ordinary"
    , accounts = []
    , accountSummaries = []
    , parentAccountOptions = []
    , accountKindOptions = []
    , collapsedAccounts = []
    , reportOptions = []
    , reportDefinition = Nothing
    , reportColumns = []
    , genericReportRows = []
    , barChartDefinitions = []
    , barChartPoints = []
    , assets = []
    , accountTypes = []
    , selectedBook = Nothing
    , selectedAccount = Nothing
    , selectedReport = Nothing
    , reconciliationAccount = Nothing
    , ledger = []
    , journal = []
    , reconciliationRows = []
    , reportDate = ""
    , reportFrom = ""
    , reportTo = ""
    , bookIdInput = ""
    , bookNameInput = ""
    , bookAssetInput = ""
    , bookEntityTypeInput = "household"
    , bookSettingsNameInput = ""
    , bookSettingsEntityTypeInput = "household"
    , bookCurrencyInput = ""
    , bookCurrencyEffectiveFromInput = ""
    , bookDeleteConfirmationInput = ""
    , bookAccessGithubInput = ""
    , bookAccessLevelInput = "rw"
    , companyLegalNameInput = ""
    , companyNumberInput = ""
    , companyLegalFormInput = "private_limited_shares"
    , companyFrameworkInput = "frs105"
    , companyUtrInput = ""
    , companyVatRegistrationInput = ""
    , companyVatSchemeInput = "not_registered"
    , companyRegisteredOfficeInput = ""
    , companyIncorporatedOnInput = ""
    , companyNotesInput = ""
    , companyPeriodIdInput = ""
    , companyPeriodStartInput = ""
    , companyPeriodEndInput = ""
    , companyPeriodStatusInput = "open"
    , companyAccountsDueInput = ""
    , companyCorporationTaxDueInput = ""
    , companyAccountsFiledInput = ""
    , companyCt600FiledInput = ""
    , companyPeriodNotesInput = ""
    , companyVatControlInput = ""
    , panamaLegalNameInput = ""
    , panamaRucInput = ""
    , panamaVerificationDigitInput = ""
    , panamaLegalFormInput = "corporation"
    , panamaMunicipalityInput = "panama_district"
    , panamaIncorporatedOnInput = ""
    , panamaResidentAgentInput = ""
    , panamaRegisteredAddressInput = ""
    , panamaOperationsNoticeInput = ""
    , panamaItbmsRegisteredInput = False
    , panamaLodgingActivityInput = False
    , panamaPropertyEnabledInput = False
    , panamaNotesInput = ""
    , panamaPeriodIdInput = ""
    , panamaPeriodStartInput = ""
    , panamaPeriodEndInput = ""
    , panamaPeriodStatusInput = "open"
    , panamaIncomeTaxDueInput = ""
    , panamaMunicipalDueInput = ""
    , panamaPeriodNotesInput = ""
    , taiwanLegalNameInput = ""
    , taiwanUnifiedBusinessNumberInput = ""
    , taiwanLegalFormInput = "limited_company"
    , taiwanTaxFrequencyInput = "bimonthly"
    , taiwanUsesUniformInvoicesInput = True
    , taiwanEstablishedOnInput = ""
    , taiwanResponsiblePersonInput = ""
    , taiwanRegisteredAddressInput = ""
    , taiwanTaxRegistrationNotesInput = ""
    , taiwanManufacturingEnabledInput = False
    , taiwanNotesInput = ""
    , taiwanPeriodIdInput = ""
    , taiwanPeriodStartInput = ""
    , taiwanPeriodEndInput = ""
    , taiwanPeriodStatusInput = "open"
    , taiwanAnnualIncomeTaxDueInput = ""
    , taiwanProvisionalIncomeTaxDueInput = ""
    , taiwanUndistributedEarningsDueInput = ""
    , taiwanPeriodNotesInput = ""
    , accountIdInput = ""
    , accountTypeInput = ""
    , accountAssetInput = ""
    , accountParentInput = ""
    , accountKindInput = "posting"
    , accountPlaceholderInput = False
    , accountPretaxInput = ""
    , openingBalanceInput = ""
    , openingDateInput = ""
    , transactionXid = Nothing
    , transactionSimple = True
    , transactionPrimaryKey = 1
    , transactionDirty = False
    , committedTransactionXid = Nothing
    , ledgerSync = LedgerIdle
    , transactionDate = ""
    , transactionComment = ""
    , draftLines = [ emptyDraft 1, emptyDraft 2 ]
    , nextDraftKey = 3
    , fieldSnapshot = Nothing
    , draftBalance = Nothing
    , nextDraftBalanceRequestId = 1
    , activeDraftBalanceRequestId = Nothing
    , pageValidation = []
    , loading = True
    , navigationLocked = False
    , nextPageRequestId = 1
    , activePageRequestId = Nothing
    , status = StatusKey "status.loading"
    , presentation = Dict.empty
    , language = "en-GB"
    , pendingLanguage = Nothing
    , languageOptions = []
    , languageMenuOpen = False
    }


emptyDraft : Int -> DraftLine
emptyDraft key =
    { key = key, account = "", amount = "", memo = "" }


type Msg
    = LinkClicked Browser.UrlRequest
    | UrlChanged Url
    | GotPage Int Page (Maybe String) (Result Http.Error (List Component))
    | ToggleLanguageMenu
    | CloseLanguageMenu
    | MoveLanguageFocus String Int
    | LanguageFocusFinished (Result Browser.Dom.Error ())
    | SelectLanguage String
    | LanguageChanged String
    | UpdateGlobalUserGithub String
    | SubmitGlobalUser
    | GlobalUserSaved (Result Http.Error (List Component))
    | SetGlobalUserEnabled String Bool String
    | GlobalUserEnabled (Result Http.Error (List Component))
    | SelectAccount String
    | SelectReconciliationAccount String
    | UpdateReportDate String
    | UpdateReportFrom String
    | UpdateReportTo String
    | RefreshReport
    | UpdateBookId String
    | UpdateBookName String
    | UpdateBookAsset String
    | UpdateBookEntityType String
    | SubmitBook
    | BookCreated (Result Http.Error (List Book))
    | UpdateBookSettingsName String
    | UpdateBookSettingsEntityType String
    | SubmitBookSettings
    | BookSettingsSaved (Result Http.Error (List Component))
    | UpdateBookCurrency String
    | UpdateBookCurrencyEffectiveFrom String
    | SubmitBookCurrency
    | BookCurrencySaved (Result Http.Error (List Component))
    | ArchiveBook
    | RestoreBook
    | UpdateBookDeleteConfirmation String
    | DeleteBook
    | BookLifecycleSaved BookLifecycleAction (Result Http.Error (List Component))
    | UpdateBookAccessGithub String
    | UpdateBookAccessLevel String
    | SubmitBookAccess
    | ChangeBookAccess String String
    | RemoveBookAccess String
    | BookAccessSaved (Result Http.Error (List Component))
    | UpdateCompanyLegalName String
    | UpdateCompanyNumber String
    | UpdateCompanyLegalForm String
    | UpdateCompanyFramework String
    | UpdateCompanyUtr String
    | UpdateCompanyVatRegistration String
    | UpdateCompanyVatScheme String
    | UpdateCompanyRegisteredOffice String
    | UpdateCompanyIncorporatedOn String
    | UpdateCompanyNotes String
    | UpdateCompanyPeriodId String
    | UpdateCompanyPeriodStart String
    | UpdateCompanyPeriodEnd String
    | UpdateCompanyPeriodStatus String
    | UpdateCompanyAccountsDue String
    | UpdateCompanyCorporationTaxDue String
    | UpdateCompanyAccountsFiled String
    | UpdateCompanyCt600Filed String
    | UpdateCompanyPeriodNotes String
    | UpdateCompanyVatControl String
    | SubmitCompanySettings
    | CompanySettingsSaved (Result Http.Error (List Component))
    | UpdatePanamaLegalName String
    | UpdatePanamaRuc String
    | UpdatePanamaVerificationDigit String
    | UpdatePanamaLegalForm String
    | UpdatePanamaMunicipality String
    | UpdatePanamaIncorporatedOn String
    | UpdatePanamaResidentAgent String
    | UpdatePanamaRegisteredAddress String
    | UpdatePanamaOperationsNotice String
    | UpdatePanamaItbmsRegistered Bool
    | UpdatePanamaLodgingActivity Bool
    | UpdatePanamaPropertyEnabled Bool
    | UpdatePanamaNotes String
    | UpdatePanamaPeriodId String
    | UpdatePanamaPeriodStart String
    | UpdatePanamaPeriodEnd String
    | UpdatePanamaPeriodStatus String
    | UpdatePanamaIncomeTaxDue String
    | UpdatePanamaMunicipalDue String
    | UpdatePanamaPeriodNotes String
    | SubmitPanamaSettings
    | PanamaSettingsSaved (Result Http.Error (List Component))
    | UpdateTaiwanLegalName String
    | UpdateTaiwanUnifiedBusinessNumber String
    | UpdateTaiwanLegalForm String
    | UpdateTaiwanTaxFrequency String
    | UpdateTaiwanUsesUniformInvoices Bool
    | UpdateTaiwanEstablishedOn String
    | UpdateTaiwanResponsiblePerson String
    | UpdateTaiwanRegisteredAddress String
    | UpdateTaiwanTaxRegistrationNotes String
    | UpdateTaiwanManufacturingEnabled Bool
    | UpdateTaiwanNotes String
    | UpdateTaiwanPeriodId String
    | UpdateTaiwanPeriodStart String
    | UpdateTaiwanPeriodEnd String
    | UpdateTaiwanPeriodStatus String
    | UpdateTaiwanAnnualIncomeTaxDue String
    | UpdateTaiwanProvisionalIncomeTaxDue String
    | UpdateTaiwanUndistributedEarningsDue String
    | UpdateTaiwanPeriodNotes String
    | SubmitTaiwanSettings
    | TaiwanSettingsSaved (Result Http.Error (List Component))
    | UpdateAccountId String
    | ToggleAccountTree String
    | UpdateAccountParent String
    | UpdateAccountType String
    | UpdateAccountAsset String
    | UpdateAccountKind String
    | UpdateAccountPlaceholder Bool
    | UpdateAccountPretax String
    | UpdateOpeningBalance String
    | UpdateOpeningDate String
    | SubmitAccount
    | AccountCreated (Result Http.Error (List Account))
    | StartNewTransaction
    | EditTransaction LedgerEntry
    | UseSplitTransaction
    | FocusRegisterField RegisterField String
    | RevertRegisterField RegisterField
    | UpdateTransactionDate String
    | UpdateTransactionComment String
    | UpdateDraftAccount Int String
    | UpdateDraftAmount Int String
    | UpdateDraftMemo Int String
    | MaterializeDraftAccount String
    | MaterializeDraftAmount String
    | MaterializeDraftMemo String
    | RefreshDraftBalance
    | DraftBalanceLoaded Int (Result Http.Error (List DraftBalance))
    | SubmitTransaction
    | TransactionSaved (Result Http.Error (List MutationResult))
    | SetPostingReconciled Int String Bool
    | PostingReconciled (Result Http.Error (List PostingReconciliation))


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        LinkClicked request ->
            case request of
                Browser.External url ->
                    ( model, Nav.load url )

                Browser.Internal url ->
                    if model.transactionDirty || model.navigationLocked then
                        ( { model | status = StatusKey "status.transaction.finish-before-navigation" }, Cmd.none )

                    else
                        case model.navigationKey of
                            Just key ->
                                ( model, Nav.pushUrl key (Url.toString url) )

                            Nothing ->
                                ( model, Cmd.none )

        UrlChanged url ->
            if model.transactionDirty || model.navigationLocked then
                case model.navigationKey of
                    Just key ->
                        ( model, Nav.replaceUrl key model.currentUrl )

                    Nothing ->
                        ( model, Cmd.none )

            else
                let
                    route =
                        routeFromUrl url

                    reset =
                        resetTransactionEditor model

                    routedModel =
                        { reset
                            | selectedBook = route.book
                            , selectedAccount = route.account
                            , reconciliationAccount = Nothing
                            , pendingRoute = Nothing
                            , currentUrl = Url.toString url
                        }
                in
                case route.book of
                    Just _ ->
                        loadRoute route routedModel

                    Nothing ->
                        startPageRequest (loadShell model.language)
                            (loadingModel route.page (loadingLabel route.page)
                                { routedModel | pendingRoute = Just route }
                            )

        GotPage requestId requestedPage requestedAccount result ->
            if model.activePageRequestId /= Just requestId then
                ( model, Cmd.none )

            else
                case result of
                    Err err ->
                        ( httpError err model, Cmd.none )

                    Ok components ->
                        let
                            next =
                                applyPage requestedPage components model

                            selectedBook =
                                next.selectedBook

                        in
                        if requestedPage == ShellPage then
                            let
                                pending =
                                    Maybe.withDefault
                                        { page = ShellPage, book = Nothing, account = Nothing, report = Nothing }
                                        model.pendingRoute

                                routed =
                                    { pending | book = selectedBook }
                            in
                            if pending.page == AddBookPage then
                                startPageRequest (loadAddBookPage model.language)
                                    (loadingModel AddBookPage (loadingLabel AddBookPage)
                                        { next | pendingRoute = Nothing }
                                    )

                            else if pending.page == AdminPage then
                                startPageRequest (loadAdmin model.language)
                                    (loadingModel AdminPage (loadingLabel AdminPage)
                                        { next | pendingRoute = Nothing, selectedBook = Nothing }
                                    )

                            else if pending.page == ShellPage then
                                finishPageRequest ShellPage
                                    { next
                                        | loading = False
                                        , navigationLocked = False
                                        , activePageRequestId = Nothing
                                        , status = StatusIdle
                                        , pendingRoute = Nothing
                                    }

                            else case ( selectedBook, next.navigationKey ) of
                                ( Just _, Just key ) ->
                                    ( { next | pendingRoute = Nothing }
                                    , Nav.replaceUrl key (routeHref routed)
                                    )

                                ( Just _, Nothing ) ->
                                    loadRoute routed { next | pendingRoute = Nothing }

                                _ ->
                                    finishPageRequest ShellPage
                                        { next
                                            | loading = False
                                            , navigationLocked = False
                                            , activePageRequestId = Nothing
                                            , status = StatusIdle
                                            , pendingRoute = Nothing
                                        }

                        else
                            finishPageRequest requestedPage
                                { next
                                    | loading = False
                                    , navigationLocked = False
                                    , activePageRequestId = Nothing
                                    , status = StatusIdle
                                    , pendingRoute = Nothing
                                }

        ToggleLanguageMenu ->
            if model.transactionDirty || model.navigationLocked then
                ( model, Cmd.none )

            else if model.languageMenuOpen then
                ( { model | languageMenuOpen = False }, focusElement "language-trigger" )

            else
                ( { model | languageMenuOpen = True }
                , focusElement (languageOptionId model.language)
                )

        CloseLanguageMenu ->
            ( { model | languageMenuOpen = False }, focusElement "language-trigger" )

        MoveLanguageFocus locale direction ->
            ( model
            , focusElement
                (languageOptionId (adjacentLanguage locale direction model.languageOptions))
            )

        LanguageFocusFinished _ ->
            ( model, Cmd.none )

        SelectLanguage language ->
            if language == model.language || not (languageIsOffered language model) then
                ( { model | languageMenuOpen = False }, Cmd.none )

            else
                changeLanguage language model

        LanguageChanged language ->
            if language == model.language then
                ( { model | pendingLanguage = Nothing }, Cmd.none )

            else if model.transactionDirty || model.navigationLocked then
                ( { model | pendingLanguage = Just language }, Cmd.none )

            else if languageIsOffered language model then
                changeLanguage language model

            else
                ( model, Cmd.none )

        UpdateGlobalUserGithub value ->
            ( { model | globalUserGithubInput = value }, Cmd.none )

        SubmitGlobalUser ->
            ( { model | navigationLocked = True, status = StatusKey "status.admin.inviting-user" }
            , inviteGlobalUser model.language model.globalUserGithubInput
            )

        GlobalUserSaved result ->
            case result of
                Err err ->
                    ( httpError err model, Cmd.none )

                Ok components ->
                    let
                        next =
                            applyPage AdminPage components model
                    in
                    ( { next
                        | globalUserGithubInput = ""
                        , navigationLocked = False
                        , status = StatusKey "status.admin.user-invited"
                      }
                    , Cmd.none
                    )

        SetGlobalUserEnabled principalId enabled actionLabel ->
            if model.navigationLocked then
                ( model, Cmd.none )

            else
                ( { model | navigationLocked = True, status = StatusText actionLabel }
                , setGlobalUserEnabled model.language principalId enabled
                )

        GlobalUserEnabled result ->
            case result of
                Err err ->
                    ( httpError err model, Cmd.none )

                Ok components ->
                    let
                        next =
                            applyPage AdminPage components model
                    in
                    ( { next | navigationLocked = False, status = StatusIdle }, Cmd.none )

        SelectAccount raw ->
            if model.transactionDirty || model.navigationLocked then
                ( model, Cmd.none )

            else if raw == addAccountValue then
                case model.selectedBook of
                    Just bookId ->
                        pushRoute
                            { page = AddAccountPage, book = Just bookId, account = Nothing, report = Nothing }
                            model

                    Nothing ->
                        ( { model | status = StatusKey "status.book.select-first" }, Cmd.none )

            else
                case model.selectedBook of
                    Just bookId ->
                        pushRoute { page = LedgerPage, book = Just bookId, account = Just raw, report = Nothing } model

                    Nothing ->
                        ( model, Cmd.none )

        SelectReconciliationAccount raw ->
            if model.transactionDirty || model.navigationLocked then
                ( model, Cmd.none )

            else
              case model.selectedBook of
                Just bookId ->
                    let
                        account =
                            nonBlankMaybe raw
                    in
                    pushRoute { page = ReconciliationPage, book = Just bookId, account = account, report = Nothing } model

                Nothing ->
                    ( { model | status = StatusKey "status.book.select-first" }, Cmd.none )

        UpdateReportDate value ->
            ( { model | reportDate = value, pageValidation = [] }, Cmd.none )

        UpdateReportFrom value ->
            ( { model | reportFrom = value, pageValidation = [] }, Cmd.none )

        UpdateReportTo value ->
            ( { model | reportTo = value, pageValidation = [] }, Cmd.none )

        RefreshReport ->
            case model.selectedBook of
                Just bookId ->
                    startPageRequest
                        (\requestId -> loadCurrentPage requestId model.page bookId model.selectedAccount model)
                        (loadingModel model.page "status.report.refreshing" model)

                Nothing ->
                    ( model, Cmd.none )

        UpdateBookId value ->
            ( { model | bookIdInput = value }, Cmd.none )

        UpdateBookName value ->
            ( { model | bookNameInput = value }, Cmd.none )

        UpdateBookAsset value ->
            ( { model | bookAssetInput = value }, Cmd.none )

        UpdateBookEntityType value ->
            ( { model | bookEntityTypeInput = value }, Cmd.none )

        SubmitBook ->
            ( { model | loading = True, navigationLocked = True, status = StatusKey "status.book.creating" }, createBook model )

        BookCreated result ->
            case result |> Result.andThen firstResult of
                Err err ->
                    ( httpError err model, Cmd.none )

                Ok book ->
                    startPageRequest (loadShellFor model.language (Just book.id))
                        { model
                            | selectedBook = Just book.id
                            , pendingRoute = Just
                                { page = AccountsPage, book = Just book.id, account = Nothing, report = Nothing }
                            , navigationLocked = False
                        }

        UpdateBookSettingsName value ->
            ( { model | bookSettingsNameInput = value }, Cmd.none )

        UpdateBookSettingsEntityType value ->
            ( { model | bookSettingsEntityTypeInput = value }, Cmd.none )

        SubmitBookSettings ->
            case model.selectedBook of
                Just bookId ->
                    ( { model | loading = True, navigationLocked = True, status = StatusKey "status.book.saving-details" }
                    , updateBookSettings model.language bookId model.bookSettingsNameInput model.bookSettingsEntityTypeInput
                    )

                Nothing ->
                    ( { model | status = StatusKey "status.book.select-first" }, Cmd.none )

        BookSettingsSaved result ->
            case result of
                Err err ->
                    ( httpError err model, Cmd.none )

                Ok components ->
                    let
                        next =
                            applyPage BookPage components model
                    in
                    ( { next | loading = False, navigationLocked = False, status = StatusKey "status.book.details-saved" }
                    , Cmd.none
                    )

        UpdateBookCurrency value ->
            ( { model | bookCurrencyInput = value }, Cmd.none )

        UpdateBookCurrencyEffectiveFrom value ->
            ( { model | bookCurrencyEffectiveFromInput = value }, Cmd.none )

        SubmitBookCurrency ->
            case model.selectedBook of
                Just bookId ->
                    ( { model | loading = True, navigationLocked = True, status = StatusKey "status.book.updating-currency" }
                    , setBookReportingCurrency bookId model
                    )

                Nothing ->
                    ( { model | status = StatusKey "status.book.select-first" }, Cmd.none )

        BookCurrencySaved result ->
            case result of
                Err err ->
                    ( httpError err model, Cmd.none )

                Ok components ->
                    let
                        next =
                            applyPage BookPage components model
                    in
                    ( { next | loading = False, navigationLocked = False, status = StatusKey "status.book.currency-updated" }
                    , Cmd.none
                    )

        ArchiveBook ->
            case model.selectedBook of
                Just bookId ->
                    ( { model | loading = True, navigationLocked = True, status = StatusKey "status.book.archiving" }
                    , changeBookLifecycle model.language "archive_book" ArchiveLifecycle bookId Nothing
                    )

                Nothing ->
                    ( { model | status = StatusKey "status.book.select-first" }, Cmd.none )

        RestoreBook ->
            case model.bookIdentity of
                Just identity ->
                    ( { model | loading = True, navigationLocked = True, status = StatusKey "status.book.restoring" }
                    , changeBookLifecycle model.language "restore_book" RestoreLifecycle identity.id Nothing
                    )

                Nothing ->
                    ( model, Cmd.none )

        UpdateBookDeleteConfirmation value ->
            ( { model | bookDeleteConfirmationInput = value }, Cmd.none )

        DeleteBook ->
            case model.bookIdentity of
                Just identity ->
                    ( { model | loading = True, navigationLocked = True, status = StatusKey "status.book.deleting" }
                    , changeBookLifecycle model.language "delete_book" DeleteLifecycle identity.id (Just model.bookDeleteConfirmationInput)
                    )

                Nothing ->
                    ( model, Cmd.none )

        BookLifecycleSaved action result ->
            case result of
                Err err ->
                    ( httpError err model, Cmd.none )

                Ok components ->
                    if action == DeleteLifecycle then
                        let
                            next =
                                applyPage ShellPage components model
                        in
                        pushRoute
                            { page = ShellPage, book = Nothing, account = Nothing, report = Nothing }
                            { next
                                | selectedBook = Nothing
                                , loading = False
                                , navigationLocked = False
                                , status = StatusKey (bookLifecycleSuccessKey action)
                            }

                    else
                        let
                            next =
                                applyPage BookPage components model
                        in
                        ( { next | loading = False, navigationLocked = False, status = StatusKey (bookLifecycleSuccessKey action) }
                        , Cmd.none
                        )

        UpdateBookAccessGithub value ->
            ( { model | bookAccessGithubInput = value }, Cmd.none )

        UpdateBookAccessLevel value ->
            ( { model | bookAccessLevelInput = value }, Cmd.none )

        SubmitBookAccess ->
            case model.selectedBook of
                Just bookId ->
                    ( { model | navigationLocked = True, status = StatusKey "status.access.adding" }
                    , inviteBookUser model.language bookId model.bookAccessGithubInput model.bookAccessLevelInput
                    )

                Nothing ->
                    ( { model | status = StatusKey "status.book.select-first" }, Cmd.none )

        ChangeBookAccess principalId accessLevel ->
            case model.selectedBook of
                Just bookId ->
                    ( { model | navigationLocked = True, status = StatusKey "status.access.changing" }
                    , updateBookAccess model.language bookId principalId accessLevel
                    )

                Nothing ->
                    ( model, Cmd.none )

        RemoveBookAccess principalId ->
            case model.selectedBook of
                Just bookId ->
                    ( { model | navigationLocked = True, status = StatusKey "status.access.removing" }
                    , removeBookAccess model.language bookId principalId
                    )

                Nothing ->
                    ( model, Cmd.none )

        BookAccessSaved result ->
            case result of
                Err err ->
                    ( httpError err model, Cmd.none )

                Ok components ->
                    let
                        accessRows =
                            filterComponents bookAccessOption components

                        accessOptions =
                            filterComponents bookAccessLevelOption components

                        pagePresentation =
                            components
                                |> List.filterMap
                                    (\component ->
                                        case component of
                                            PresentationComponent key value ->
                                                Just ( key, value )

                                            _ ->
                                                Nothing
                                    )
                                |> Dict.fromList

                        next =
                            { model
                                | bookAccess = accessRows
                                , bookAccessLevelOptions = accessOptions
                                , presentation = Dict.union pagePresentation model.presentation
                            }
                    in
                    ( { next
                        | bookAccessGithubInput = ""
                        , navigationLocked = False
                        , status = StatusKey "status.access.updated"
                      }
                    , Cmd.none
                    )

        UpdateCompanyLegalName value ->
            ( { model | companyLegalNameInput = value }, Cmd.none )

        UpdateCompanyNumber value ->
            ( { model | companyNumberInput = value }, Cmd.none )

        UpdateCompanyLegalForm value ->
            ( { model | companyLegalFormInput = value }, Cmd.none )

        UpdateCompanyFramework value ->
            ( { model | companyFrameworkInput = value }, Cmd.none )

        UpdateCompanyUtr value ->
            ( { model | companyUtrInput = value }, Cmd.none )

        UpdateCompanyVatRegistration value ->
            ( { model | companyVatRegistrationInput = value }, Cmd.none )

        UpdateCompanyVatScheme value ->
            ( { model | companyVatSchemeInput = value }, Cmd.none )

        UpdateCompanyRegisteredOffice value ->
            ( { model | companyRegisteredOfficeInput = value }, Cmd.none )

        UpdateCompanyIncorporatedOn value ->
            ( { model | companyIncorporatedOnInput = value }, Cmd.none )

        UpdateCompanyNotes value ->
            ( { model | companyNotesInput = value }, Cmd.none )

        UpdateCompanyPeriodId value ->
            ( { model | companyPeriodIdInput = value }, Cmd.none )

        UpdateCompanyPeriodStart value ->
            ( { model | companyPeriodStartInput = value }, Cmd.none )

        UpdateCompanyPeriodEnd value ->
            ( { model | companyPeriodEndInput = value }, Cmd.none )

        UpdateCompanyPeriodStatus value ->
            ( { model | companyPeriodStatusInput = value }, Cmd.none )

        UpdateCompanyAccountsDue value ->
            ( { model | companyAccountsDueInput = value }, Cmd.none )

        UpdateCompanyCorporationTaxDue value ->
            ( { model | companyCorporationTaxDueInput = value }, Cmd.none )

        UpdateCompanyAccountsFiled value ->
            ( { model | companyAccountsFiledInput = value }, Cmd.none )

        UpdateCompanyCt600Filed value ->
            ( { model | companyCt600FiledInput = value }, Cmd.none )

        UpdateCompanyPeriodNotes value ->
            ( { model | companyPeriodNotesInput = value }, Cmd.none )

        UpdateCompanyVatControl value ->
            ( { model | companyVatControlInput = value }, Cmd.none )

        SubmitCompanySettings ->
            case model.selectedBook of
                Just bookId ->
                    ( { model | loading = True, navigationLocked = True, status = StatusKey "status.uk-company.saving" }
                    , configureUkCompany bookId model
                    )

                Nothing ->
                    ( { model | status = StatusKey "status.book.select-first" }, Cmd.none )

        CompanySettingsSaved result ->
            case result of
                Err err ->
                    ( httpError err model, Cmd.none )

                Ok components ->
                    let
                        next =
                            applyPage BookPage components model
                    in
                    ( { next | loading = False, navigationLocked = False, status = StatusKey "status.uk-company.saved" }
                    , Cmd.none
                    )

        UpdatePanamaLegalName value ->
            ( { model | panamaLegalNameInput = value }, Cmd.none )

        UpdatePanamaRuc value ->
            ( { model | panamaRucInput = value }, Cmd.none )

        UpdatePanamaVerificationDigit value ->
            ( { model | panamaVerificationDigitInput = value }, Cmd.none )

        UpdatePanamaLegalForm value ->
            ( { model | panamaLegalFormInput = value }, Cmd.none )

        UpdatePanamaMunicipality value ->
            ( { model | panamaMunicipalityInput = value }, Cmd.none )

        UpdatePanamaIncorporatedOn value ->
            ( { model | panamaIncorporatedOnInput = value }, Cmd.none )

        UpdatePanamaResidentAgent value ->
            ( { model | panamaResidentAgentInput = value }, Cmd.none )

        UpdatePanamaRegisteredAddress value ->
            ( { model | panamaRegisteredAddressInput = value }, Cmd.none )

        UpdatePanamaOperationsNotice value ->
            ( { model | panamaOperationsNoticeInput = value }, Cmd.none )

        UpdatePanamaItbmsRegistered value ->
            ( { model | panamaItbmsRegisteredInput = value }, Cmd.none )

        UpdatePanamaLodgingActivity value ->
            ( { model | panamaLodgingActivityInput = value }, Cmd.none )

        UpdatePanamaPropertyEnabled value ->
            ( { model | panamaPropertyEnabledInput = value }, Cmd.none )

        UpdatePanamaNotes value ->
            ( { model | panamaNotesInput = value }, Cmd.none )

        UpdatePanamaPeriodId value ->
            ( { model | panamaPeriodIdInput = value }, Cmd.none )

        UpdatePanamaPeriodStart value ->
            ( { model | panamaPeriodStartInput = value }, Cmd.none )

        UpdatePanamaPeriodEnd value ->
            ( { model | panamaPeriodEndInput = value }, Cmd.none )

        UpdatePanamaPeriodStatus value ->
            ( { model | panamaPeriodStatusInput = value }, Cmd.none )

        UpdatePanamaIncomeTaxDue value ->
            ( { model | panamaIncomeTaxDueInput = value }, Cmd.none )

        UpdatePanamaMunicipalDue value ->
            ( { model | panamaMunicipalDueInput = value }, Cmd.none )

        UpdatePanamaPeriodNotes value ->
            ( { model | panamaPeriodNotesInput = value }, Cmd.none )

        SubmitPanamaSettings ->
            case model.selectedBook of
                Just bookId ->
                    ( { model | loading = True, navigationLocked = True, status = StatusKey "status.panama-business.saving" }
                    , configurePanamaBusiness bookId model
                    )

                Nothing ->
                    ( { model | status = StatusKey "status.book.select-first" }, Cmd.none )

        PanamaSettingsSaved result ->
            case result of
                Err err ->
                    ( httpError err model, Cmd.none )

                Ok components ->
                    let
                        next =
                            applyPage BookPage components model
                    in
                    ( { next | loading = False, navigationLocked = False, status = StatusKey "status.panama-business.saved" }
                    , Cmd.none
                    )

        UpdateTaiwanLegalName value ->
            ( { model | taiwanLegalNameInput = value }, Cmd.none )

        UpdateTaiwanUnifiedBusinessNumber value ->
            ( { model | taiwanUnifiedBusinessNumberInput = value }, Cmd.none )

        UpdateTaiwanLegalForm value ->
            ( { model | taiwanLegalFormInput = value }, Cmd.none )

        UpdateTaiwanTaxFrequency value ->
            ( { model | taiwanTaxFrequencyInput = value }, Cmd.none )

        UpdateTaiwanUsesUniformInvoices value ->
            ( { model | taiwanUsesUniformInvoicesInput = value }, Cmd.none )

        UpdateTaiwanEstablishedOn value ->
            ( { model | taiwanEstablishedOnInput = value }, Cmd.none )

        UpdateTaiwanResponsiblePerson value ->
            ( { model | taiwanResponsiblePersonInput = value }, Cmd.none )

        UpdateTaiwanRegisteredAddress value ->
            ( { model | taiwanRegisteredAddressInput = value }, Cmd.none )

        UpdateTaiwanTaxRegistrationNotes value ->
            ( { model | taiwanTaxRegistrationNotesInput = value }, Cmd.none )

        UpdateTaiwanManufacturingEnabled value ->
            ( { model | taiwanManufacturingEnabledInput = value }, Cmd.none )

        UpdateTaiwanNotes value ->
            ( { model | taiwanNotesInput = value }, Cmd.none )

        UpdateTaiwanPeriodId value ->
            ( { model | taiwanPeriodIdInput = value }, Cmd.none )

        UpdateTaiwanPeriodStart value ->
            ( { model | taiwanPeriodStartInput = value }, Cmd.none )

        UpdateTaiwanPeriodEnd value ->
            ( { model | taiwanPeriodEndInput = value }, Cmd.none )

        UpdateTaiwanPeriodStatus value ->
            ( { model | taiwanPeriodStatusInput = value }, Cmd.none )

        UpdateTaiwanAnnualIncomeTaxDue value ->
            ( { model | taiwanAnnualIncomeTaxDueInput = value }, Cmd.none )

        UpdateTaiwanProvisionalIncomeTaxDue value ->
            ( { model | taiwanProvisionalIncomeTaxDueInput = value }, Cmd.none )

        UpdateTaiwanUndistributedEarningsDue value ->
            ( { model | taiwanUndistributedEarningsDueInput = value }, Cmd.none )

        UpdateTaiwanPeriodNotes value ->
            ( { model | taiwanPeriodNotesInput = value }, Cmd.none )

        SubmitTaiwanSettings ->
            case model.selectedBook of
                Just bookId ->
                    ( { model | loading = True, navigationLocked = True, status = StatusKey "status.taiwan-business.saving" }
                    , configureTaiwanBusiness bookId model
                    )

                Nothing ->
                    ( { model | status = StatusKey "status.book.select-first" }, Cmd.none )

        TaiwanSettingsSaved result ->
            case result of
                Err err ->
                    ( httpError err model, Cmd.none )

                Ok components ->
                    let
                        next =
                            applyPage BookPage components model
                    in
                    ( { next | loading = False, navigationLocked = False, status = StatusKey "status.taiwan-business.saved" }
                    , Cmd.none
                    )

        UpdateAccountId value ->
            ( { model | accountIdInput = value }, Cmd.none )

        ToggleAccountTree accountId ->
            if List.member accountId model.collapsedAccounts then
                ( { model | collapsedAccounts = List.filter ((/=) accountId) model.collapsedAccounts }, Cmd.none )

            else
                ( { model | collapsedAccounts = accountId :: model.collapsedAccounts }, Cmd.none )

        UpdateAccountParent value ->
            ( selectAccountParent value model, Cmd.none )

        UpdateAccountType value ->
            ( ensureCompatibleAccountKind { model | accountTypeInput = value }, Cmd.none )

        UpdateAccountAsset value ->
            ( { model | accountAssetInput = value }, Cmd.none )

        UpdateAccountKind value ->
            ( { model
                | accountKindInput = value
                , accountPlaceholderInput = model.accountPlaceholderInput || value == "group"
              }
            , Cmd.none
            )

        UpdateAccountPlaceholder value ->
            ( { model | accountPlaceholderInput = value }, Cmd.none )

        UpdateAccountPretax value ->
            ( { model | accountPretaxInput = value }, Cmd.none )

        UpdateOpeningBalance value ->
            ( { model | openingBalanceInput = value }, Cmd.none )

        UpdateOpeningDate value ->
            ( { model | openingDateInput = value }, Cmd.none )

        SubmitAccount ->
            case model.selectedBook of
                Just bookId ->
                    ( { model | loading = True, navigationLocked = True, status = StatusKey "status.account.creating" }
                    , createAccount bookId model
                    )

                Nothing ->
                    ( { model | status = StatusKey "status.book.select-first" }, Cmd.none )

        AccountCreated result ->
            case result |> Result.andThen firstResult of
                Err err ->
                    ( httpError err model, Cmd.none )

                Ok account ->
                    if model.accountPlaceholderInput then
                        pushRoute
                            { page = AccountsPage, book = Just account.bookId, account = Nothing, report = Nothing }
                            { model | navigationLocked = False }

                    else
                        pushRoute
                            { page = LedgerPage, book = Just account.bookId, account = Just account.id, report = Nothing }
                            { model | navigationLocked = False }

        StartNewTransaction ->
            case model.ledgerSync of
                LedgerIdle ->
                    if model.transactionXid /= Nothing && model.transactionDirty then
                        saveTransactionFor OpenLedgerAppend model

                    else
                        ( ensureAppendPrimary (resetTransactionEditor model), Cmd.none )

                _ ->
                    ( retargetLedgerSync OpenLedgerAppend model, Cmd.none )

        EditTransaction entry ->
            selectTransaction entry model

        UseSplitTransaction ->
            requestDraftBalance
                (markTransactionDirty { model | transactionSimple = False })

        FocusRegisterField field value ->
            ( { model
                | fieldSnapshot =
                    Just
                        { field = field
                        , value = value
                        , dirtyBefore = model.transactionDirty
                        , draftExistedBefore = registerFieldDraftExists field model
                        , draftAmountBefore = registerFieldDraftAmount field model
                        , draftBalanceBefore = model.draftBalance
                        }
              }
            , Cmd.none
            )

        RevertRegisterField field ->
            applyPendingLanguageIfReady (revertRegisterField field model)

        UpdateTransactionDate value ->
            ( markTransactionDirty { model | transactionDate = value }, Cmd.none )

        UpdateTransactionComment value ->
            ( markTransactionDirty { model | transactionComment = value }, Cmd.none )

        UpdateDraftAccount key value ->
            ( updateDraftAccount key value model, Cmd.none )

        UpdateDraftAmount key value ->
            ( invalidateDraftBalance (updateDraft key (\line -> { line | amount = value }) model), Cmd.none )

        UpdateDraftMemo key value ->
            ( updateDraft key (\line -> { line | memo = value }) model, Cmd.none )

        MaterializeDraftAccount value ->
            ( materializeDraftAccount value model, Cmd.none )

        MaterializeDraftAmount value ->
            ( materializeDraft False (\line -> { line | amount = value }) model, Cmd.none )

        MaterializeDraftMemo value ->
            ( materializeDraft True (\line -> { line | memo = value }) model, Cmd.none )

        RefreshDraftBalance ->
            requestDraftBalance model

        DraftBalanceLoaded requestId result ->
            if model.activeDraftBalanceRequestId /= Just requestId then
                ( model, Cmd.none )

            else
                case result of
                    Ok balances ->
                        ( { model
                            | draftBalance = chooseDraftBalance model balances
                            , activeDraftBalanceRequestId = Nothing
                          }
                        , Cmd.none
                        )

                    Err _ ->
                        ( { model
                            | draftBalance = Nothing
                            , activeDraftBalanceRequestId = Nothing
                          }
                        , Cmd.none
                        )

        SubmitTransaction ->
            case model.ledgerSync of
                LedgerIdle ->
                    saveTransactionFor FinishLedgerTransaction model

                _ ->
                    ( model, Cmd.none )

        TransactionSaved result ->
            case result |> Result.andThen firstResult of
                Err err ->
                    ( httpError err
                        { model
                            | ledgerSync = LedgerIdle
                        }
                    , Cmd.none
                    )

                Ok saved ->
                    let
                        destination =
                            ledgerSyncDestination model.ledgerSync
                                |> Maybe.withDefault FinishLedgerTransaction
                    in
                    reloadLedger "status.ledger.refreshing"
                        { model
                            | transactionDirty = False
                            , committedTransactionXid = Just saved.xid
                            , ledgerSync = LedgerRefreshing destination
                        }

        SetPostingReconciled xid account reconciled ->
            case model.selectedBook of
                Just bookId ->
                    if model.navigationLocked then
                        ( model, Cmd.none )

                    else
                        ( { model
                            | navigationLocked = True
                            , status = StatusKey (if reconciled then "status.reconciliation.marking" else "status.reconciliation.reopening")
                          }
                        , setPostingReconciled bookId xid account reconciled
                        )

                Nothing ->
                    ( { model | status = StatusKey "status.book.select-first" }, Cmd.none )

        PostingReconciled result ->
            case result |> Result.andThen firstResult of
                Err err ->
                    ( httpError err model, Cmd.none )

                Ok posting ->
                    ( { model
                        | reconciliationRows =
                            List.map
                                (\row ->
                                    if row.xid == posting.xid && row.account == posting.account then
                                        { row | reconciled = posting.reconciled }

                                    else
                                        row
                                )
                                model.reconciliationRows
                        , navigationLocked = False
                        , status = StatusKey (if posting.reconciled then "status.reconciliation.reconciled" else "status.reconciliation.reopened")
                      }
                    , Cmd.none
                    )

loadingModel : Page -> String -> Model -> Model
loadingModel page statusKey model =
    { model | page = page, loading = True, navigationLocked = False, status = StatusKey statusKey }


languageIsOffered : String -> Model -> Bool
languageIsOffered language model =
    List.any (\option -> option.locale == language) model.languageOptions


changeLanguage : String -> Model -> ( Model, Cmd Msg )
changeLanguage language model =
    let
        ( changed, request ) =
            changeLanguageWithoutSaving language model
    in
    ( changed, Cmd.batch [ saveLanguage language, request ] )


changeLanguageWithoutSaving : String -> Model -> ( Model, Cmd Msg )
changeLanguageWithoutSaving language model =
    let
        route =
            { page = model.page
            , book = model.selectedBook
            , account =
                if model.page == ReconciliationPage then
                    model.reconciliationAccount

                else
                    model.selectedAccount
            , report = model.selectedReport
            }

        changed =
            { model
                | language = language
                , pendingLanguage = Nothing
                , languageMenuOpen = False
                , presentation = Dict.empty
                , pendingRoute = Just route
            }
    in
    if model.page == AddBookPage then
        startPageRequest (loadAddBookPage language)
            (loadingModel AddBookPage "status.loading" changed)

    else
        startPageRequest (loadShellFor language route.book)
            (loadingModel route.page "status.loading" changed)


finishPageRequest : Page -> Model -> ( Model, Cmd Msg )
finishPageRequest page model =
    applyPendingLanguageIfReady (finishReadyPage page model)


applyPendingLanguageIfReady : Model -> ( Model, Cmd Msg )
applyPendingLanguageIfReady model =
    case model.pendingLanguage of
        Just language ->
            if language == model.language || not (languageIsOffered language model) then
                ( { model | pendingLanguage = Nothing }, Cmd.none )

            else if not model.transactionDirty && not model.navigationLocked then
                changeLanguage language { model | pendingLanguage = Nothing }

            else
                ( model, Cmd.none )

        Nothing ->
            ( model, Cmd.none )


startPageRequest : (Int -> Cmd Msg) -> Model -> ( Model, Cmd Msg )
startPageRequest request model =
    startPageRequestWith True request model


startPreservingPageRequest : (Int -> Cmd Msg) -> Model -> ( Model, Cmd Msg )
startPreservingPageRequest request model =
    startPageRequestWith False request model


startPageRequestWith : Bool -> (Int -> Cmd Msg) -> Model -> ( Model, Cmd Msg )
startPageRequestWith clearRows request model =
    let
        requestId =
            model.nextPageRequestId

        prepared =
            if clearRows then
                clearPageRows model.page model

            else
                model

        cancelPrevious =
            model.activePageRequestId
                |> Maybe.map (pageRequestTracker >> Http.cancel)
                |> Maybe.withDefault Cmd.none
    in
    ( { prepared
        | nextPageRequestId = requestId + 1
        , activePageRequestId = Just requestId
        , pageValidation = []
      }
    , Cmd.batch [ cancelPrevious, request requestId ]
    )


pageRequestTracker : Int -> String
pageRequestTracker requestId =
    "njord-page-" ++ String.fromInt requestId


clearPageRows : Page -> Model -> Model
clearPageRows page model =
    case page of
        AdminPage ->
            { model
                | globalUsers = []
                , bookIdentity = Nothing
                , bookAccess = []
                , bookAccessLevelOptions = []
            }

        BookPage ->
            { model
                | bookIdentity = Nothing
                , companyProfile = Nothing
                , accountingPeriods = []
                , configurationChecks = []
            }

        AccountsPage ->
            { model | accountSummaries = [] }

        LedgerPage ->
            { model | ledger = [] }

        GeneralJournalPage ->
            { model | journal = [] }

        ReconciliationPage ->
            { model | reconciliationRows = [] }

        ReportPage ->
            { model
                | reportDefinition = Nothing
                , reportColumns = []
                , genericReportRows = []
                , barChartDefinitions = []
                , barChartPoints = []
            }

        _ ->
            model


markTransactionDirty : Model -> Model
markTransactionDirty model =
    { model | transactionDirty = True }


updateDraft : Int -> (DraftLine -> DraftLine) -> Model -> Model
updateDraft key change model =
    markTransactionDirty
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


materializeDraft : Bool -> (DraftLine -> DraftLine) -> Model -> Model
materializeDraft preserveBalance change model =
    let
        base =
            emptyDraft model.nextDraftKey
    in
    markTransactionDirty
        { model
            | draftLines = model.draftLines ++ [ change base ]
            , nextDraftKey = model.nextDraftKey + 1
            , transactionSimple = False
            , draftBalance =
                if preserveBalance then
                    model.draftBalance

                else
                    Nothing
            , activeDraftBalanceRequestId = Nothing
        }


materializeDraftAccount : String -> Model -> Model
materializeDraftAccount account model =
    let
        suggestion =
            suggestedAmountForAccount account model

        base =
            emptyDraft model.nextDraftKey
    in
    markTransactionDirty
        { model
            | draftLines =
                model.draftLines
                    ++ [ { base
                            | account = account
                            , amount = Maybe.withDefault "" suggestion
                         }
                       ]
            , nextDraftKey = model.nextDraftKey + 1
            , transactionSimple = False
            , draftBalance =
                case suggestion of
                    Just _ ->
                        Nothing

                    Nothing ->
                        model.draftBalance
            , activeDraftBalanceRequestId = Nothing
        }


updateDraftAccount : Int -> String -> Model -> Model
updateDraftAccount key account model =
    let
        existing =
            model.draftLines
                |> List.filter (\line -> line.key == key)
                |> List.head

        suggestion =
            case existing of
                Just line ->
                    if String.trim line.amount == "" then
                        suggestedAmountForAccount account model

                    else
                        Nothing

                Nothing ->
                    Nothing

        updated =
            updateDraft key
                (\line ->
                    { line
                        | account = account
                        , amount = Maybe.withDefault line.amount suggestion
                    }
                )
                model
    in
    case ( existing, suggestion ) of
        ( Just line, Nothing ) ->
            if String.trim line.amount == "" && model.draftBalance /= Nothing then
                { updated | activeDraftBalanceRequestId = Nothing }

            else
                invalidateDraftBalance updated

        _ ->
            invalidateDraftBalance updated


suggestedAmountForAccount : String -> Model -> Maybe String
suggestedAmountForAccount accountId model =
    case model.draftBalance of
        Just balance ->
            model.accounts
                |> List.filter (\account -> account.id == accountId && account.asset == balance.asset)
                |> List.head
                |> Maybe.map (\_ -> balance.amount)

        Nothing ->
            Nothing


revertRegisterField : RegisterField -> Model -> Model
revertRegisterField field model =
    case model.fieldSnapshot of
        Just snapshot ->
            if snapshot.field /= field then
                model

            else
                let
                    restored =
                        case field of
                            TransactionDateField ->
                                { model | transactionDate = snapshot.value }

                            TransactionCommentField ->
                                { model | transactionComment = snapshot.value }

                            DraftAccountField key ->
                                if snapshot.draftExistedBefore then
                                    restoreDraft key
                                        (\line ->
                                            { line
                                                | account = snapshot.value
                                                , amount = Maybe.withDefault line.amount snapshot.draftAmountBefore
                                            }
                                        )
                                        model

                                else
                                    removeDraft key model

                            DraftAmountField key ->
                                if snapshot.draftExistedBefore then
                                    restoreDraft key (\line -> { line | amount = snapshot.value }) model

                                else
                                    removeDraft key model

                            DraftMemoField key ->
                                if snapshot.draftExistedBefore then
                                    restoreDraft key (\line -> { line | memo = snapshot.value }) model

                                else
                                    removeDraft key model
                in
                { restored
                    | fieldSnapshot = Nothing
                    , transactionDirty = snapshot.dirtyBefore
                    , draftBalance = snapshot.draftBalanceBefore
                    , activeDraftBalanceRequestId = Nothing
                    , status = StatusKey "status.field.cancelled"
                }

        Nothing ->
            model


restoreDraft : Int -> (DraftLine -> DraftLine) -> Model -> Model
restoreDraft key change model =
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


removeDraft : Int -> Model -> Model
removeDraft key model =
    { model | draftLines = List.filter (\line -> line.key /= key) model.draftLines }


registerFieldDraftExists : RegisterField -> Model -> Bool
registerFieldDraftExists field model =
    case field of
        DraftAccountField key ->
            List.any (\line -> line.key == key) model.draftLines

        DraftAmountField key ->
            List.any (\line -> line.key == key) model.draftLines

        DraftMemoField key ->
            List.any (\line -> line.key == key) model.draftLines

        _ ->
            True


registerFieldDraftAmount : RegisterField -> Model -> Maybe String
registerFieldDraftAmount field model =
    let
        amountFor key =
            model.draftLines
                |> List.filter (\line -> line.key == key)
                |> List.head
                |> Maybe.map .amount
    in
    case field of
        DraftAccountField key ->
            amountFor key

        DraftAmountField key ->
            amountFor key

        DraftMemoField key ->
            amountFor key

        _ ->
            Nothing


draftLineIsBlank : DraftLine -> Bool
draftLineIsBlank line =
    String.trim line.account == ""
        && String.trim line.amount == ""
        && String.trim line.memo == ""


nonBlankDraftLines : Model -> List DraftLine
nonBlankDraftLines model =
    List.filter (not << draftLineIsBlank) model.draftLines


draftLineIsSubmittable : DraftLine -> Bool
draftLineIsSubmittable line =
    if String.trim line.account == "" || String.trim line.amount == "" then
        False

    else
        decimalPolarity line.amount /= DecimalZero


submittableDraftLines : Model -> List DraftLine
submittableDraftLines model =
    List.filter draftLineIsSubmittable model.draftLines


validDraftBalanceLine : DraftLine -> Bool
validDraftBalanceLine line =
    if String.trim line.account == "" then
        False

    else
        case decimalPolarity line.amount of
            DecimalPositive ->
                True

            DecimalNegative ->
                True

            _ ->
                False


draftBalanceLines : Model -> List DraftLine
draftBalanceLines model =
    List.filter validDraftBalanceLine model.draftLines


invalidateDraftBalance : Model -> Model
invalidateDraftBalance model =
    { model
        | draftBalance = Nothing
        , activeDraftBalanceRequestId = Nothing
    }


requestDraftBalance : Model -> ( Model, Cmd Msg )
requestDraftBalance model =
    let
        lines =
            draftBalanceLines model
    in
    if model.transactionSimple || model.navigationLocked then
        ( invalidateDraftBalance model, Cmd.none )

    else
        case ( model.selectedBook, lines ) of
            ( Just bookId, _ :: _ ) ->
                let
                    requestId =
                        model.nextDraftBalanceRequestId
                in
                ( { model
                    | nextDraftBalanceRequestId = requestId + 1
                    , activeDraftBalanceRequestId = Just requestId
                  }
                , loadDraftBalance requestId bookId lines
                )

            _ ->
                ( invalidateDraftBalance model, Cmd.none )


chooseDraftBalance : Model -> List DraftBalance -> Maybe DraftBalance
chooseDraftBalance model balances =
    let
        primaryAsset =
            primaryDraftLine model
                |> Maybe.andThen
                    (\primary ->
                        model.accounts
                            |> List.filter (\account -> account.id == primary.account)
                            |> List.head
                            |> Maybe.map .asset
                    )
    in
    case primaryAsset of
        Just asset ->
            balances
                |> List.filter (\balance -> balance.asset == asset)
                |> List.head

        Nothing ->
            case balances of
                [ balance ] ->
                    Just balance

                _ ->
                    Nothing


resetTransactionEditor : Model -> Model
resetTransactionEditor model =
    { model
        | transactionXid = Nothing
        , transactionSimple = True
        , transactionPrimaryKey = 1
        , transactionDirty = False
        , committedTransactionXid = Nothing
        , ledgerSync = LedgerIdle
        , transactionDate = ""
        , transactionComment = ""
        , draftLines = [ emptyDraft 1, emptyDraft 2 ]
        , nextDraftKey = 3
        , fieldSnapshot = Nothing
        , draftBalance = Nothing
        , activeDraftBalanceRequestId = Nothing
    }


ensureAppendPrimary : Model -> Model
ensureAppendPrimary model =
    case ( model.transactionXid, model.selectedAccount, model.draftLines ) of
        ( Nothing, Just accountId, first :: rest ) ->
            { model
                | transactionPrimaryKey = first.key
                , draftLines = { first | account = accountId } :: rest
            }

        _ ->
            model


activateTransaction : LedgerEntry -> Model -> Model
activateTransaction entry model =
    let
        drafts =
            entry.lines
                |> List.indexedMap
                    (\index line ->
                        { key = index + 1
                        , account = line.account
                        , amount = line.amount
                        , memo = Maybe.withDefault "" line.comment
                        }
                    )

        primaryKey =
            drafts
                |> List.filter (\line -> line.account == entry.account)
                |> List.head
                |> Maybe.map .key
                |> Maybe.withDefault 1
    in
    { model
        | transactionXid = Just entry.xid
        , transactionSimple = not entry.split && List.length entry.lines == 2
        , transactionPrimaryKey = primaryKey
        , transactionDirty = False
        , committedTransactionXid = Nothing
        , ledgerSync = LedgerIdle
        , transactionDate = entry.date
        , transactionComment = Maybe.withDefault "" entry.transactionComment
        , draftLines = drafts
        , nextDraftKey = List.length drafts + 1
        , fieldSnapshot = Nothing
        , draftBalance = Nothing
        , activeDraftBalanceRequestId = Nothing
        , status = StatusKey "status.transaction.editing"
    }


selectTransaction : LedgerEntry -> Model -> ( Model, Cmd Msg )
selectTransaction entry model =
    case model.ledgerSync of
        LedgerIdle ->
            if model.transactionXid == Just entry.xid then
                ( model, Cmd.none )

            else if model.transactionDirty then
                saveTransactionFor (OpenLedgerTransaction entry.xid) model

            else
                ( activateTransaction entry model, Cmd.none )

        _ ->
            ( retargetLedgerSync (OpenLedgerTransaction entry.xid) model, Cmd.none )


saveTransactionFor : LedgerDestination -> Model -> ( Model, Cmd Msg )
saveTransactionFor destination model =
    case model.selectedBook of
        Just bookId ->
            ( { model
                | navigationLocked = True
                , ledgerSync = LedgerSaving destination
                , status = StatusKey "status.transaction.saving"
              }
            , saveTransaction bookId model
            )

        Nothing ->
            ( model, Cmd.none )


finishReadyPage : Page -> Model -> Model
finishReadyPage page model =
    if page /= LedgerPage then
        model

    else
        case model.ledgerSync of
            LedgerRefreshing destination ->
                finishLedgerDestination destination model

            _ ->
                ensureAppendPrimary model


finishLedgerDestination : LedgerDestination -> Model -> Model
finishLedgerDestination destination model =
    case destination of
        OpenLedgerTransaction xid ->
            case model.ledger |> List.filter (\entry -> entry.xid == xid) |> List.head of
                Just entry ->
                    activateTransaction entry model

                Nothing ->
                    let
                        reset =
                            resetTransactionEditor model
                    in
                    ensureAppendPrimary
                        { reset
                            | status = StatusKey "status.transaction.saved-not-visible"
                        }

        OpenLedgerAppend ->
            ensureAppendPrimary (resetTransactionEditor model)

        FinishLedgerTransaction ->
            ensureAppendPrimary (resetTransactionEditor model)


ledgerSyncDestination : LedgerSync -> Maybe LedgerDestination
ledgerSyncDestination sync =
    case sync of
        LedgerSaving destination ->
            Just destination

        LedgerRefreshing destination ->
            Just destination

        LedgerIdle ->
            Nothing


retargetLedgerSync : LedgerDestination -> Model -> Model
retargetLedgerSync destination model =
    case model.ledgerSync of
        LedgerSaving _ ->
            { model | ledgerSync = LedgerSaving destination }

        LedgerRefreshing _ ->
            { model | ledgerSync = LedgerRefreshing destination }

        LedgerIdle ->
            model


reloadLedger : String -> Model -> ( Model, Cmd Msg )
reloadLedger statusKey model =
    case ( model.selectedBook, model.selectedAccount ) of
        ( Just bookId, Just accountId ) ->
            startPreservingPageRequest
                (\requestId -> loadLedger model.language requestId bookId accountId)
                { model
                    | page = LedgerPage
                    , loading = False
                    , navigationLocked = True
                    , status = StatusKey statusKey
                }

        _ ->
            ( { model
                | loading = False
                , navigationLocked = False
                , activePageRequestId = Nothing
                , ledgerSync = LedgerIdle
                , status = StatusKey statusKey
              }
            , Cmd.none
            )


firstResult : List a -> Result Http.Error a
firstResult rows =
    case rows of
        first :: _ ->
            Ok first

        [] ->
            Err (Http.BadBody "error.database.no-rows")


httpError : Http.Error -> Model -> Model
httpError err model =
    let
        status =
            case model.ledgerSync of
                LedgerRefreshing _ ->
                    StatusTemplate "error.transaction-refresh"
                        [ ( "error", errorToString model err ) ]

                _ ->
                    StatusText (errorToString model err)
    in
    { model
        | loading = False
        , navigationLocked = False
        , activePageRequestId = Nothing
        , ledgerSync = LedgerIdle
        , status = status
    }


applyPage : Page -> List Component -> Model -> Model
applyPage page components model =
    let
        pageBooks =
            filterComponents (\component -> case component of
                BookComponent value -> Just value
                _ -> Nothing
            ) components

        books =
            if page == ShellPage || page == AdminPage || page == AddBookPage || List.isEmpty model.books then
                pageBooks

            else
                let
                    replaceBook existing =
                        pageBooks
                            |> List.filter (\candidate -> candidate.id == existing.id)
                            |> List.head
                            |> Maybe.map
                                (\candidate ->
                                    if candidate.accessLevel == "" then
                                        { candidate | accessLevel = existing.accessLevel }

                                    else
                                        candidate
                                )
                            |> Maybe.withDefault existing

                    knownIds =
                        List.map .id model.books
                in
                List.map replaceBook model.books
                    ++ List.filter (\candidate -> not (List.member candidate.id knownIds)) pageBooks

        accounts =
            filterComponents (\component -> case component of
                AccountComponent value -> Just value
                _ -> Nothing
            ) components

        selectedBook =
            if List.any (\book -> Just book.id == model.selectedBook) books then
                model.selectedBook

            else if page == ShellPage || page == AdminPage || page == AddBookPage then
                books
                    |> List.filter .selected
                    |> List.head
                    |> Maybe.andThen (.id >> nonBlankMaybe)

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

        pagePresentation =
            components
                |> List.filterMap
                    (\component ->
                        case component of
                            PresentationComponent key value ->
                                Just ( key, value )

                            _ ->
                                Nothing
                    )
                |> Dict.fromList

        pageGlobalAdmin =
            components
                |> List.filterMap adminContextOption
                |> List.head
                |> Maybe.withDefault model.globalAdmin

        pageModel =
            { model
                | page = page
                , books = books
                , globalAdmin = pageGlobalAdmin
                , globalUsers =
                    if page == AdminPage then
                        filterComponents globalUserOption components

                    else
                        model.globalUsers
                , bookIdentity = filterComponents bookIdentityOption components |> List.head
                , bookAccess =
                    let
                        rows =
                            filterComponents bookAccessOption components
                    in
                    if List.isEmpty rows then model.bookAccess else rows
                , bookAccessLevelOptions =
                    let
                        options =
                            filterComponents bookAccessLevelOption components
                    in
                    if List.isEmpty options then model.bookAccessLevelOptions else options
                , bookEntityTypeOptions = filterComponents bookEntityTypeOption components
                , reportingCurrencies = filterComponents reportingCurrencyOption components
                , companyProfile = filterComponents companyProfileOption components |> List.head
                , panamaBusinessProfile = filterComponents panamaBusinessProfileOption components |> List.head
                , taiwanBusinessProfile = filterComponents taiwanBusinessProfileOption components |> List.head
                , legalFormOptions = filterComponents legalFormOption components
                , accountingFrameworkOptions = filterComponents accountingFrameworkOption components
                , vatSchemeOptions = filterComponents vatSchemeOption components
                , periodStatusOptions = filterComponents periodStatusOption components
                , accountingPeriods = filterComponents accountingPeriodOption components
                , vatControlAccountOptions = filterComponents vatControlAccountOption components
                , configurationChecks = filterComponents configurationCheckOption components
                , panamaLegalFormOptions = filterComponents panamaLegalFormOption components
                , panamaMunicipalityOptions = filterComponents panamaMunicipalityOption components
                , panamaPeriodStatusOptions = filterComponents panamaPeriodStatusOption components
                , panamaFiscalPeriods = filterComponents panamaFiscalPeriodOption components
                , taiwanLegalFormOptions = filterComponents taiwanLegalFormOption components
                , taiwanTaxFrequencyOptions = filterComponents taiwanTaxFrequencyOption components
                , taiwanPeriodStatusOptions = filterComponents taiwanPeriodStatusOption components
                , taiwanFiscalPeriods = filterComponents taiwanFiscalPeriodOption components
                , accounts = accounts
                , accountSummaries = filterComponents accountSummaryOption components
                , parentAccountOptions = filterComponents parentAccountOption components
                , accountKindOptions = filterComponents accountKindOption components
                , reportOptions = filterComponents reportOption components
                , reportDefinition = filterComponents reportDefinitionOption components |> List.head
                , reportColumns = filterComponents reportColumnOption components
                , genericReportRows = filterComponents genericReportRowOption components
                , barChartDefinitions = filterComponents barChartDefinitionOption components
                , barChartPoints = filterComponents barChartPointOption components
                , assets = filterComponents assetOption components
                , accountTypes = filterComponents accountTypeOption components
                , selectedBook = selectedBook
                , selectedAccount = selectedAccount
                , ledger = filterComponents ledgerOption components
                , journal = filterComponents journalOption components
                , reconciliationRows = filterComponents reconciliationOption components
                , pageValidation = []
                , presentation = Dict.union pagePresentation model.presentation
                , languageOptions = filterComponents languageOption components
            }

        contextualModel =
            applyPageContext page pageContext pageModel
    in
    if page == BookPage then
        hydrateBookInputs contextualModel

    else
        contextualModel


fallbackBook : Book
fallbackBook =
    { id = "", name = "", reportingAsset = "GBP", accessLevel = "", selected = False }


filterComponents : (Component -> Maybe a) -> List Component -> List a
filterComponents select components =
    List.filterMap select components


languageOption : Component -> Maybe LanguageOption
languageOption component =
    case component of
        LanguageOptionComponent value -> Just value
        _ -> Nothing


adminContextOption : Component -> Maybe Bool
adminContextOption component =
    case component of
        AdminContextComponent value -> Just value
        _ -> Nothing


globalUserOption : Component -> Maybe GlobalUser
globalUserOption component =
    case component of
        GlobalUserComponent value -> Just value
        _ -> Nothing


bookIdentityOption : Component -> Maybe BookIdentity
bookIdentityOption component =
    case component of
        BookIdentityComponent value -> Just value
        _ -> Nothing


bookAccessOption : Component -> Maybe BookAccess
bookAccessOption component =
    case component of
        BookAccessComponent value -> Just value
        _ -> Nothing


bookAccessLevelOption : Component -> Maybe NamedOption
bookAccessLevelOption component =
    case component of
        BookAccessLevelOptionComponent value -> Just value
        _ -> Nothing


bookEntityTypeOption : Component -> Maybe NamedOption
bookEntityTypeOption component =
    case component of
        BookEntityTypeOptionComponent value -> Just value
        _ -> Nothing


reportingCurrencyOption : Component -> Maybe ReportingCurrency
reportingCurrencyOption component =
    case component of
        ReportingCurrencyComponent value -> Just value
        _ -> Nothing


companyProfileOption : Component -> Maybe CompanyProfile
companyProfileOption component =
    case component of
        CompanyProfileComponent value -> Just value
        _ -> Nothing


panamaBusinessProfileOption : Component -> Maybe PanamaBusinessProfile
panamaBusinessProfileOption component =
    case component of
        PanamaBusinessProfileComponent value -> Just value
        _ -> Nothing


panamaLegalFormOption : Component -> Maybe NamedOption
panamaLegalFormOption component =
    case component of
        PanamaLegalFormOptionComponent value -> Just value
        _ -> Nothing


panamaMunicipalityOption : Component -> Maybe NamedOption
panamaMunicipalityOption component =
    case component of
        PanamaMunicipalityOptionComponent value -> Just value
        _ -> Nothing


panamaPeriodStatusOption : Component -> Maybe NamedOption
panamaPeriodStatusOption component =
    case component of
        PanamaPeriodStatusOptionComponent value -> Just value
        _ -> Nothing


panamaFiscalPeriodOption : Component -> Maybe PanamaFiscalPeriod
panamaFiscalPeriodOption component =
    case component of
        PanamaFiscalPeriodComponent value -> Just value
        _ -> Nothing


taiwanBusinessProfileOption : Component -> Maybe TaiwanBusinessProfile
taiwanBusinessProfileOption component =
    case component of
        TaiwanBusinessProfileComponent value -> Just value
        _ -> Nothing


taiwanLegalFormOption : Component -> Maybe NamedOption
taiwanLegalFormOption component =
    case component of
        TaiwanLegalFormOptionComponent value -> Just value
        _ -> Nothing


taiwanTaxFrequencyOption : Component -> Maybe NamedOption
taiwanTaxFrequencyOption component =
    case component of
        TaiwanTaxFrequencyOptionComponent value -> Just value
        _ -> Nothing


taiwanPeriodStatusOption : Component -> Maybe NamedOption
taiwanPeriodStatusOption component =
    case component of
        TaiwanPeriodStatusOptionComponent value -> Just value
        _ -> Nothing


taiwanFiscalPeriodOption : Component -> Maybe TaiwanFiscalPeriod
taiwanFiscalPeriodOption component =
    case component of
        TaiwanFiscalPeriodComponent value -> Just value
        _ -> Nothing


legalFormOption : Component -> Maybe NamedOption
legalFormOption component =
    case component of
        LegalFormOptionComponent value -> Just value
        _ -> Nothing


accountingFrameworkOption : Component -> Maybe NamedOption
accountingFrameworkOption component =
    case component of
        AccountingFrameworkOptionComponent value -> Just value
        _ -> Nothing


vatSchemeOption : Component -> Maybe NamedOption
vatSchemeOption component =
    case component of
        VatSchemeOptionComponent value -> Just value
        _ -> Nothing


periodStatusOption : Component -> Maybe NamedOption
periodStatusOption component =
    case component of
        PeriodStatusOptionComponent value -> Just value
        _ -> Nothing


accountingPeriodOption : Component -> Maybe AccountingPeriod
accountingPeriodOption component =
    case component of
        AccountingPeriodComponent value -> Just value
        _ -> Nothing


vatControlAccountOption : Component -> Maybe VatControlAccountOption
vatControlAccountOption component =
    case component of
        VatControlAccountOptionComponent value -> Just value
        _ -> Nothing


configurationCheckOption : Component -> Maybe ConfigurationCheck
configurationCheckOption component =
    case component of
        ConfigurationCheckComponent value -> Just value
        _ -> Nothing


reportOption : Component -> Maybe ReportOption
reportOption component =
    case component of
        ReportOptionComponent value -> Just value
        _ -> Nothing


reportDefinitionOption : Component -> Maybe ReportDefinition
reportDefinitionOption component =
    case component of
        ReportDefinitionComponent value -> Just value
        _ -> Nothing


reportColumnOption : Component -> Maybe ReportColumn
reportColumnOption component =
    case component of
        ReportColumnComponent value -> Just value
        _ -> Nothing


genericReportRowOption : Component -> Maybe GenericReportRow
genericReportRowOption component =
    case component of
        GenericReportRowComponent value -> Just value
        _ -> Nothing


barChartDefinitionOption : Component -> Maybe BarChartDefinition
barChartDefinitionOption component =
    case component of
        BarChartDefinitionComponent value -> Just value
        _ -> Nothing


barChartPointOption : Component -> Maybe BarChartPoint
barChartPointOption component =
    case component of
        BarChartPointComponent value -> Just value
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


accountSummaryOption : Component -> Maybe AccountSummary
accountSummaryOption component =
    case component of
        AccountSummaryComponent value -> Just value
        _ -> Nothing


parentAccountOption : Component -> Maybe ParentAccountOption
parentAccountOption component =
    case component of
        ParentAccountOptionComponent value -> Just value
        _ -> Nothing


accountKindOption : Component -> Maybe AccountKindOption
accountKindOption component =
    case component of
        AccountKindOptionComponent value -> Just value
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


reconciliationOption : Component -> Maybe ReconciliationEntry
reconciliationOption component =
    case component of
        ReconciliationComponent value -> Just value
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
                BookPage ->
                    { pageModel
                        | bookExists = value.bookExists
                        , bookConfigurationStatus = value.configurationStatus
                    }

                ReportPage ->
                    { pageModel
                        | reportDate = Maybe.withDefault "" value.asOf
                        , reportFrom = Maybe.withDefault "" value.fromDate
                        , reportTo = Maybe.withDefault "" value.toDate
                    }

                AddBookPage ->
                    { pageModel
                        | bookAssetInput = Maybe.withDefault model.bookAssetInput value.reportingAsset
                    }

                AddAccountPage ->
                    ensureCompatibleAccountKind
                        { pageModel
                            | accountTypeInput = Maybe.withDefault model.accountTypeInput value.accountType
                            , accountAssetInput = Maybe.withDefault model.accountAssetInput value.asset
                            , accountParentInput = Maybe.withDefault "" value.parentId
                            , accountKindInput = Maybe.withDefault "posting" value.accountKind
                            , accountPlaceholderInput = value.placeholder
                            , accountPretaxInput = Maybe.withDefault model.accountPretaxInput value.pretax
                            , openingDateInput = Maybe.withDefault model.openingDateInput value.openingDate
                        }

                _ ->
                    pageModel


hydrateBookInputs : Model -> Model
hydrateBookInputs model =
    let
        identity =
            Maybe.withDefault fallbackBookIdentity model.bookIdentity

        profile =
            Maybe.withDefault
                { enabled = False
                , legalName = identity.name
                , companyNumber = Nothing
                , legalForm = "private_limited_shares"
                , accountingFramework = "frs105"
                , utr = Nothing
                , vatRegistrationNumber = Nothing
                , vatScheme = "not_registered"
                , registeredOffice = Nothing
                , incorporatedOn = Nothing
                , notes = Nothing
                }
                model.companyProfile

        period =
            Maybe.withDefault
                { id = ""
                , periodStart = ""
                , periodEnd = ""
                , status = "open"
                , accountsDueOn = Nothing
                , corporationTaxDueOn = Nothing
                , accountsFiledOn = Nothing
                , ct600FiledOn = Nothing
                , notes = Nothing
                }
                (List.head model.accountingPeriods)

        vatControl =
            model.vatControlAccountOptions
                |> List.filter .selected
                |> List.head
                |> Maybe.map .id
                |> Maybe.withDefault ""

        panamaProfile =
            Maybe.withDefault
                { enabled = False
                , legalName = identity.name
                , ruc = ""
                , verificationDigit = Nothing
                , legalForm = "corporation"
                , municipality = "panama_district"
                , incorporatedOn = Nothing
                , residentAgent = Nothing
                , registeredAddress = Nothing
                , operationsNoticeNumber = Nothing
                , itbmsRegistered = False
                , conductsLodgingActivity = False
                , residentialPropertyEnabled = False
                , propertyCount = 0
                , notes = Nothing
                }
                model.panamaBusinessProfile

        panamaPeriod =
            Maybe.withDefault
                { id = ""
                , periodStart = ""
                , periodEnd = ""
                , status = "open"
                , incomeTaxReturnDueOn = Nothing
                , municipalReturnDueOn = Nothing
                , notes = Nothing
                }
                (List.head model.panamaFiscalPeriods)

        taiwanProfile =
            Maybe.withDefault
                { enabled = False
                , legalName = identity.name
                , unifiedBusinessNumber = ""
                , legalForm = "limited_company"
                , businessTaxFrequency = "bimonthly"
                , usesUniformInvoices = True
                , establishedOn = Nothing
                , responsiblePerson = Nothing
                , registeredAddress = Nothing
                , taxRegistrationNotes = Nothing
                , manufacturingEnabled = False
                , inventoryItemCount = 0
                , notes = Nothing
                }
                model.taiwanBusinessProfile

        taiwanPeriod =
            Maybe.withDefault
                { id = ""
                , periodStart = ""
                , periodEnd = ""
                , status = "open"
                , annualIncomeTaxDueOn = Nothing
                , provisionalIncomeTaxDueOn = Nothing
                , undistributedEarningsDueOn = Nothing
                , notes = Nothing
                }
                (List.head model.taiwanFiscalPeriods)
    in
    { model
        | bookSettingsNameInput = identity.name
        , bookSettingsEntityTypeInput = identity.entityType
        , bookCurrencyInput = identity.reportingAsset
        , bookCurrencyEffectiveFromInput = ""
        , bookDeleteConfirmationInput = ""
        , companyLegalNameInput = profile.legalName
        , companyNumberInput = Maybe.withDefault "" profile.companyNumber
        , companyLegalFormInput = profile.legalForm
        , companyFrameworkInput = profile.accountingFramework
        , companyUtrInput = Maybe.withDefault "" profile.utr
        , companyVatRegistrationInput = Maybe.withDefault "" profile.vatRegistrationNumber
        , companyVatSchemeInput = profile.vatScheme
        , companyRegisteredOfficeInput = Maybe.withDefault "" profile.registeredOffice
        , companyIncorporatedOnInput = Maybe.withDefault "" profile.incorporatedOn
        , companyNotesInput = Maybe.withDefault "" profile.notes
        , companyPeriodIdInput = period.id
        , companyPeriodStartInput = period.periodStart
        , companyPeriodEndInput = period.periodEnd
        , companyPeriodStatusInput = period.status
        , companyAccountsDueInput = Maybe.withDefault "" period.accountsDueOn
        , companyCorporationTaxDueInput = Maybe.withDefault "" period.corporationTaxDueOn
        , companyAccountsFiledInput = Maybe.withDefault "" period.accountsFiledOn
        , companyCt600FiledInput = Maybe.withDefault "" period.ct600FiledOn
        , companyPeriodNotesInput = Maybe.withDefault "" period.notes
        , companyVatControlInput = vatControl
        , panamaLegalNameInput = panamaProfile.legalName
        , panamaRucInput = panamaProfile.ruc
        , panamaVerificationDigitInput = Maybe.withDefault "" panamaProfile.verificationDigit
        , panamaLegalFormInput = panamaProfile.legalForm
        , panamaMunicipalityInput = panamaProfile.municipality
        , panamaIncorporatedOnInput = Maybe.withDefault "" panamaProfile.incorporatedOn
        , panamaResidentAgentInput = Maybe.withDefault "" panamaProfile.residentAgent
        , panamaRegisteredAddressInput = Maybe.withDefault "" panamaProfile.registeredAddress
        , panamaOperationsNoticeInput = Maybe.withDefault "" panamaProfile.operationsNoticeNumber
        , panamaItbmsRegisteredInput = panamaProfile.itbmsRegistered
        , panamaLodgingActivityInput = panamaProfile.conductsLodgingActivity
        , panamaPropertyEnabledInput = panamaProfile.residentialPropertyEnabled
        , panamaNotesInput = Maybe.withDefault "" panamaProfile.notes
        , panamaPeriodIdInput = panamaPeriod.id
        , panamaPeriodStartInput = panamaPeriod.periodStart
        , panamaPeriodEndInput = panamaPeriod.periodEnd
        , panamaPeriodStatusInput = panamaPeriod.status
        , panamaIncomeTaxDueInput = Maybe.withDefault "" panamaPeriod.incomeTaxReturnDueOn
        , panamaMunicipalDueInput = Maybe.withDefault "" panamaPeriod.municipalReturnDueOn
        , panamaPeriodNotesInput = Maybe.withDefault "" panamaPeriod.notes
        , taiwanLegalNameInput = taiwanProfile.legalName
        , taiwanUnifiedBusinessNumberInput = taiwanProfile.unifiedBusinessNumber
        , taiwanLegalFormInput = taiwanProfile.legalForm
        , taiwanTaxFrequencyInput = taiwanProfile.businessTaxFrequency
        , taiwanUsesUniformInvoicesInput = taiwanProfile.usesUniformInvoices
        , taiwanEstablishedOnInput = Maybe.withDefault "" taiwanProfile.establishedOn
        , taiwanResponsiblePersonInput = Maybe.withDefault "" taiwanProfile.responsiblePerson
        , taiwanRegisteredAddressInput = Maybe.withDefault "" taiwanProfile.registeredAddress
        , taiwanTaxRegistrationNotesInput = Maybe.withDefault "" taiwanProfile.taxRegistrationNotes
        , taiwanManufacturingEnabledInput = taiwanProfile.manufacturingEnabled
        , taiwanNotesInput = Maybe.withDefault "" taiwanProfile.notes
        , taiwanPeriodIdInput = taiwanPeriod.id
        , taiwanPeriodStartInput = taiwanPeriod.periodStart
        , taiwanPeriodEndInput = taiwanPeriod.periodEnd
        , taiwanPeriodStatusInput = taiwanPeriod.status
        , taiwanAnnualIncomeTaxDueInput = Maybe.withDefault "" taiwanPeriod.annualIncomeTaxDueOn
        , taiwanProvisionalIncomeTaxDueInput = Maybe.withDefault "" taiwanPeriod.provisionalIncomeTaxDueOn
        , taiwanUndistributedEarningsDueInput = Maybe.withDefault "" taiwanPeriod.undistributedEarningsDueOn
        , taiwanPeriodNotesInput = Maybe.withDefault "" taiwanPeriod.notes
    }


fallbackBookIdentity : BookIdentity
fallbackBookIdentity =
    { id = ""
    , name = ""
    , reportingAsset = ""
    , entityType = "household"
    , entityTypeLabel = ""
    , archivedAt = Nothing
    }


selectAccountParent : String -> Model -> Model
selectAccountParent parentId model =
    let
        withParent =
            { model | accountParentInput = parentId }
    in
    model.parentAccountOptions
        |> List.filter (\option -> option.id == parentId)
        |> List.head
        |> Maybe.map
            (\parent ->
                ensureCompatibleAccountKind
                    { withParent
                        | accountTypeInput = parent.accountType
                        , accountAssetInput = parent.asset
                    }
            )
        |> Maybe.withDefault withParent


ensureCompatibleAccountKind : Model -> Model
ensureCompatibleAccountKind model =
    let
        available =
            availableAccountKinds model

        selectedIsAvailable =
            List.any (\option -> option.id == model.accountKindInput) available

        fallback =
            available
                |> List.filter (\option -> option.id == "posting")
                |> List.head
                |> Maybe.withDefault
                    (Maybe.withDefault
                        { id = "posting", label = "", requiredType = Nothing }
                        (List.head available)
                    )
    in
    if selectedIsAvailable then
        model

    else
        { model | accountKindInput = fallback.id }


availableAccountKinds : Model -> List AccountKindOption
availableAccountKinds model =
    List.filter
        (\option ->
            case option.requiredType of
                Just requiredType ->
                    requiredType == model.accountTypeInput

                Nothing ->
                    True
        )
        model.accountKindOptions


nonBlankMaybe : String -> Maybe String
nonBlankMaybe value =
    if String.trim value == "" then
        Nothing

    else
        Just value


routeFromUrl : Url -> Route
routeFromUrl url =
    let
        slug =
            queryValue "page" url |> Maybe.withDefault "books"

        routedPage =
            pageFromSlug slug
    in
    { page = routedPage
    , book =
        if routedPage == AdminPage || routedPage == ShellPage || routedPage == AddBookPage then
            Nothing

        else
            queryValue "book" url |> Maybe.andThen nonBlankMaybe
    , account = queryValue "account" url |> Maybe.andThen nonBlankMaybe
    , report = queryValue "report" url |> Maybe.andThen nonBlankMaybe
    }


queryValue : String -> Url -> Maybe String
queryValue name url =
    url.query
        |> Maybe.withDefault ""
        |> String.split "&"
        |> List.filterMap queryPair
        |> List.filter (\( key, _ ) -> key == name)
        |> List.head
        |> Maybe.map Tuple.second


queryPair : String -> Maybe ( String, String )
queryPair raw =
    case String.split "=" raw of
        key :: values ->
            let
                decode value =
                    Url.percentDecode value |> Maybe.withDefault value
            in
            Just ( decode key, decode (String.join "=" values) )

        [] ->
            Nothing


pageFromSlug : String -> Page
pageFromSlug slug =
    case slug of
        "admin" -> AdminPage
        "book" -> BookPage
        "books" -> ShellPage
        "ledger" -> LedgerPage
        "journal" -> GeneralJournalPage
        "reconciliation" -> ReconciliationPage
        "reports" -> ReportsPage
        "report" -> ReportPage
        "add-book" -> AddBookPage
        "add-account" -> AddAccountPage
        _ -> AccountsPage


pageSlug : Page -> String
pageSlug page =
    case page of
        AdminPage -> "admin"
        BookPage -> "book"
        LedgerPage -> "ledger"
        GeneralJournalPage -> "journal"
        ReconciliationPage -> "reconciliation"
        ReportsPage -> "reports"
        ReportPage -> "report"
        AddBookPage -> "add-book"
        AddAccountPage -> "add-account"
        AccountsPage -> "accounts"
        ShellPage -> "books"


routeHref : Route -> String
routeHref route =
    let
        parameters =
            [ Just ( "page", pageSlug route.page )
            , Maybe.map (\book -> ( "book", book )) route.book
            , Maybe.map (\account -> ( "account", account )) route.account
            , Maybe.map (\report -> ( "report", report )) route.report
            ]
                |> List.filterMap identity
                |> List.map (\( key, value ) -> Url.percentEncode key ++ "=" ++ Url.percentEncode value)
    in
    "/?" ++ String.join "&" parameters


pushRoute : Route -> Model -> ( Model, Cmd Msg )
pushRoute route model =
    case model.navigationKey of
        Just key ->
            ( model, Nav.pushUrl key (routeHref route) )

        Nothing ->
            loadRoute route model


loadRoute : Route -> Model -> ( Model, Cmd Msg )
loadRoute route model =
    case route.book of
        Nothing ->
            startPageRequest (loadShell model.language)
                (loadingModel ShellPage "status.loading" { model | pendingRoute = Just route })

        Just bookId ->
            let
                routed =
                    { model
                        | selectedBook = Just bookId
                        , selectedAccount = route.account
                        , selectedReport = route.report
                        , reconciliationAccount =
                            if route.page == ReconciliationPage then route.account else Nothing
                        , reportDate = ""
                        , reportFrom = ""
                        , reportTo = ""
                    }
            in
            case ( route.page, route.account ) of
                ( LedgerPage, Just accountId ) ->
                    startPageRequest
                        (\requestId -> loadLedger model.language requestId bookId accountId)
                        (loadingModel LedgerPage "status.loading.ledger" routed)

                ( LedgerPage, Nothing ) ->
                    startPageRequest
                        (\requestId -> loadAccounts model.language requestId bookId)
                        (loadingModel AccountsPage "status.loading.accounts" routed)

                _ ->
                    startPageRequest
                        (\requestId -> loadCurrentPage requestId route.page bookId route.account routed)
                        (loadingModel route.page (loadingLabel route.page) routed)


loadingLabel : Page -> String
loadingLabel page =
    case page of
        AdminPage -> "status.loading.admin"
        BookPage -> "status.loading.book"
        AccountsPage -> "status.loading.accounts"
        LedgerPage -> "status.loading.ledger"
        GeneralJournalPage -> "status.loading.journal"
        ReconciliationPage -> "status.loading.reconciliation"
        ReportsPage -> "status.loading.reports"
        ReportPage -> "status.loading.report"
        AddBookPage -> "status.loading.add-book"
        AddAccountPage -> "status.loading.add-account"
        ShellPage -> "status.loading"


loadCurrentPage : Int -> Page -> String -> Maybe String -> Model -> Cmd Msg
loadCurrentPage requestId page bookId accountId model =
    case page of
        AdminPage ->
            loadAdmin model.language requestId

        BookPage ->
            loadBook model.language requestId bookId

        AccountsPage ->
            loadAccounts model.language requestId bookId

        LedgerPage ->
            loadLedger model.language requestId bookId (Maybe.withDefault "" accountId)

        ReportsPage ->
            loadReports model.language requestId bookId

        ReportPage ->
            loadDatabaseReport
                model.language
                requestId
                bookId
                (Maybe.withDefault "" model.selectedReport)
                model.reportDate
                model.reportFrom
                model.reportTo

        GeneralJournalPage ->
            loadGeneralJournal model.language requestId bookId

        ReconciliationPage ->
            loadReconciliation model.language requestId bookId accountId

        AddAccountPage ->
            loadAddAccountPage model.language requestId bookId accountId

        AddBookPage ->
            loadAddBookPage model.language requestId

        ShellPage ->
            loadShell model.language requestId


loadShell : String -> Int -> Cmd Msg
loadShell language requestId =
    loadShellFor language Nothing requestId


loadShellFor : String -> Maybe String -> Int -> Cmd Msg
loadShellFor language bookId requestId =
    pageRpc ControlApi language requestId ShellPage Nothing "shell_page"
        (Encode.object
            [ ( "p_book_id", Maybe.map Encode.string bookId |> Maybe.withDefault Encode.null ) ]
        )


loadAdmin : String -> Int -> Cmd Msg
loadAdmin language requestId =
    pageRpc ControlApi language requestId AdminPage Nothing "admin_page" (Encode.object [])


loadBook : String -> Int -> String -> Cmd Msg
loadBook language requestId bookId =
    pageRpc (BookApi bookId) language requestId BookPage Nothing "book_settings_page"
        (Encode.object [ ( "p_book_id", Encode.string bookId ) ])


loadLedger : String -> Int -> String -> String -> Cmd Msg
loadLedger language requestId bookId accountId =
    pageRpc (BookApi bookId) language requestId LedgerPage (nonBlankMaybe accountId) "ledger_page"
        (Encode.object
            [ ( "p_book_id", Encode.string bookId )
            , ( "p_account_id", Encode.string accountId )
            ]
        )


loadAccounts : String -> Int -> String -> Cmd Msg
loadAccounts language requestId bookId =
    pageRpc (BookApi bookId) language requestId AccountsPage Nothing "accounts_page"
        (Encode.object [ ( "p_book_id", Encode.string bookId ) ])


loadReports : String -> Int -> String -> Cmd Msg
loadReports language requestId bookId =
    pageRpc (BookApi bookId) language requestId ReportsPage Nothing "reports_page"
        (Encode.object [ ( "p_book_id", Encode.string bookId ) ])


loadDatabaseReport : String -> Int -> String -> String -> String -> String -> String -> Cmd Msg
loadDatabaseReport language requestId bookId reportId asOf fromDate toDate =
    pageRpc (BookApi bookId) language requestId ReportPage Nothing "report_page"
        (Encode.object
            [ ( "p_book_id", Encode.string bookId )
            , ( "p_report_id", Encode.string reportId )
            , ( "p_as_of", optionalEncodeString asOf )
            , ( "p_from", optionalEncodeString fromDate )
            , ( "p_to", optionalEncodeString toDate )
            ]
        )


loadGeneralJournal : String -> Int -> String -> Cmd Msg
loadGeneralJournal language requestId bookId =
    pageRpc (BookApi bookId) language requestId GeneralJournalPage Nothing "general_journal_page"
        (Encode.object [ ( "p_book_id", Encode.string bookId ) ])


loadReconciliation : String -> Int -> String -> Maybe String -> Cmd Msg
loadReconciliation language requestId bookId account =
    pageRpc (BookApi bookId) language requestId ReconciliationPage Nothing "reconciliation_page"
        (Encode.object
            [ ( "p_book_id", Encode.string bookId )
            , ( "p_account_id", Maybe.map Encode.string account |> Maybe.withDefault Encode.null )
            ]
        )


loadAddBookPage : String -> Int -> Cmd Msg
loadAddBookPage language requestId =
    pageRpc ControlApi language requestId AddBookPage Nothing "add_book_page" (Encode.object [])


loadAddAccountPage : String -> Int -> String -> Maybe String -> Cmd Msg
loadAddAccountPage language requestId bookId parentId =
    pageRpc (BookApi bookId) language requestId AddAccountPage Nothing "add_account_page"
        (Encode.object
            [ ( "p_book_id", Encode.string bookId )
            , ( "p_parent_id", Maybe.map Encode.string parentId |> Maybe.withDefault Encode.null )
            ]
        )


loadDraftBalance : Int -> String -> List DraftLine -> Cmd Msg
loadDraftBalance requestId bookId lines =
    bookRpc bookId "transaction_draft_balance_text"
        (Encode.object
            [ ( "p_book_id", Encode.string bookId )
            , ( "p_lines", Encode.list encodeDraftLine lines )
            ]
        )
        (Decode.list draftBalanceDecoder)
        (DraftBalanceLoaded requestId)


pageRpc : ApiTarget -> String -> Int -> Page -> Maybe String -> String -> Encode.Value -> Cmd Msg
pageRpc target language requestId page requestedAccount functionName body =
    apiRpcWithTrackerAndHeaders
        target
        [ Http.header "Accept-Language" language ]
        (Just (pageRequestTracker requestId))
        functionName
        body
        componentListDecoder
        (GotPage requestId page requestedAccount)


createBook : Model -> Cmd Msg
createBook model =
    controlRpc "create_book"
        (Encode.object
            [ ( "p_id", Encode.string (String.trim model.bookIdInput) )
            , ( "p_name", Encode.string (String.trim model.bookNameInput) )
            , ( "p_reporting_asset", Encode.string model.bookAssetInput )
            , ( "p_entity_type", Encode.string model.bookEntityTypeInput )
            ]
        )
        (Decode.list bookDecoder)
        BookCreated


updateBookSettings : String -> String -> String -> String -> Cmd Msg
updateBookSettings language bookId name entityType =
    bookRpcInLanguage bookId language "update_book_settings"
        (Encode.object
            [ ( "p_book_id", Encode.string bookId )
            , ( "p_name", Encode.string (String.trim name) )
            , ( "p_entity_type", Encode.string entityType )
            ]
        )
        componentListDecoder
        BookSettingsSaved


inviteBookUser : String -> String -> String -> String -> Cmd Msg
inviteBookUser language bookId githubLogin accessLevel =
    bookRpcInLanguage bookId language "invite_book_user"
        (Encode.object
            [ ( "p_book_id", Encode.string bookId )
            , ( "p_github_login", Encode.string (String.trim githubLogin) )
            , ( "p_access_level", Encode.string accessLevel )
            ]
        )
        componentListDecoder
        BookAccessSaved


inviteGlobalUser : String -> String -> Cmd Msg
inviteGlobalUser language githubLogin =
    controlRpcInLanguage language "invite_global_user"
        (Encode.object
            [ ( "p_github_login", Encode.string (String.trim githubLogin) ) ]
        )
        componentListDecoder
        GlobalUserSaved


setGlobalUserEnabled : String -> String -> Bool -> Cmd Msg
setGlobalUserEnabled language principalId enabled =
    controlRpcInLanguage language "set_global_user_enabled"
        (Encode.object
            [ ( "p_principal_id", Encode.string principalId )
            , ( "p_enabled", Encode.bool enabled )
            ]
        )
        componentListDecoder
        GlobalUserEnabled


updateBookAccess : String -> String -> String -> String -> Cmd Msg
updateBookAccess language bookId principalId accessLevel =
    bookRpcInLanguage bookId language "update_book_access"
        (Encode.object
            [ ( "p_book_id", Encode.string bookId )
            , ( "p_principal_id", Encode.string principalId )
            , ( "p_access_level", Encode.string accessLevel )
            ]
        )
        componentListDecoder
        BookAccessSaved


removeBookAccess : String -> String -> String -> Cmd Msg
removeBookAccess language bookId principalId =
    bookRpcInLanguage bookId language "remove_book_access"
        (Encode.object
            [ ( "p_book_id", Encode.string bookId )
            , ( "p_principal_id", Encode.string principalId )
            ]
        )
        componentListDecoder
        BookAccessSaved


setBookReportingCurrency : String -> Model -> Cmd Msg
setBookReportingCurrency bookId model =
    bookRpcInLanguage bookId model.language "set_book_reporting_currency"
        (Encode.object
            [ ( "p_book_id", Encode.string bookId )
            , ( "p_asset", Encode.string model.bookCurrencyInput )
            , ( "p_effective_from", optionalEncodeString model.bookCurrencyEffectiveFromInput )
            ]
        )
        componentListDecoder
        BookCurrencySaved


changeBookLifecycle : String -> String -> BookLifecycleAction -> String -> Maybe String -> Cmd Msg
changeBookLifecycle language functionName action bookId confirmation =
    bookRpcInLanguage bookId language functionName
        (Encode.object
            ([ ( "p_book_id", Encode.string bookId ) ]
                ++ (case confirmation of
                        Just name ->
                            [ ( "p_confirm_name", Encode.string name ) ]

                        Nothing ->
                            []
                   )
            )
        )
        componentListDecoder
        (BookLifecycleSaved action)


bookLifecycleSuccessKey : BookLifecycleAction -> String
bookLifecycleSuccessKey action =
    case action of
        ArchiveLifecycle ->
            "status.book.archived"

        RestoreLifecycle ->
            "status.book.restored"

        DeleteLifecycle ->
            "status.book.deleted"


configureUkCompany : String -> Model -> Cmd Msg
configureUkCompany bookId model =
    bookRpcInLanguage bookId model.language "configure_uk_company"
        (Encode.object
            [ ( "p_book_id", Encode.string bookId )
            , ( "p_legal_name", Encode.string (String.trim model.companyLegalNameInput) )
            , ( "p_company_number", optionalEncodeString model.companyNumberInput )
            , ( "p_legal_form", Encode.string model.companyLegalFormInput )
            , ( "p_accounting_framework", Encode.string model.companyFrameworkInput )
            , ( "p_utr", optionalEncodeString model.companyUtrInput )
            , ( "p_vat_registration_number", optionalEncodeString model.companyVatRegistrationInput )
            , ( "p_vat_scheme", Encode.string model.companyVatSchemeInput )
            , ( "p_registered_office", optionalEncodeString model.companyRegisteredOfficeInput )
            , ( "p_incorporated_on", optionalEncodeString model.companyIncorporatedOnInput )
            , ( "p_notes", optionalEncodeString model.companyNotesInput )
            , ( "p_period_id", Encode.string (String.trim model.companyPeriodIdInput) )
            , ( "p_period_start", optionalEncodeString model.companyPeriodStartInput )
            , ( "p_period_end", optionalEncodeString model.companyPeriodEndInput )
            , ( "p_period_status", Encode.string model.companyPeriodStatusInput )
            , ( "p_accounts_due_on", optionalEncodeString model.companyAccountsDueInput )
            , ( "p_corporation_tax_due_on", optionalEncodeString model.companyCorporationTaxDueInput )
            , ( "p_accounts_filed_on", optionalEncodeString model.companyAccountsFiledInput )
            , ( "p_ct600_filed_on", optionalEncodeString model.companyCt600FiledInput )
            , ( "p_period_notes", optionalEncodeString model.companyPeriodNotesInput )
            , ( "p_vat_control_acct", optionalEncodeString model.companyVatControlInput )
            ]
        )
        componentListDecoder
        CompanySettingsSaved


configurePanamaBusiness : String -> Model -> Cmd Msg
configurePanamaBusiness bookId model =
    bookRpcInLanguage bookId model.language "configure_panama_business"
        (Encode.object
            [ ( "p_book_id", Encode.string bookId )
            , ( "p_legal_name", Encode.string (String.trim model.panamaLegalNameInput) )
            , ( "p_ruc", Encode.string (String.trim model.panamaRucInput) )
            , ( "p_verification_digit", optionalEncodeString model.panamaVerificationDigitInput )
            , ( "p_legal_form", Encode.string model.panamaLegalFormInput )
            , ( "p_municipality", Encode.string model.panamaMunicipalityInput )
            , ( "p_incorporated_on", optionalEncodeString model.panamaIncorporatedOnInput )
            , ( "p_resident_agent", optionalEncodeString model.panamaResidentAgentInput )
            , ( "p_registered_address", optionalEncodeString model.panamaRegisteredAddressInput )
            , ( "p_operations_notice_number", optionalEncodeString model.panamaOperationsNoticeInput )
            , ( "p_itbms_registered", Encode.bool model.panamaItbmsRegisteredInput )
            , ( "p_conducts_lodging_activity", Encode.bool model.panamaLodgingActivityInput )
            , ( "p_enable_residential_property", Encode.bool model.panamaPropertyEnabledInput )
            , ( "p_notes", optionalEncodeString model.panamaNotesInput )
            , ( "p_period_id", Encode.string (String.trim model.panamaPeriodIdInput) )
            , ( "p_period_start", optionalEncodeString model.panamaPeriodStartInput )
            , ( "p_period_end", optionalEncodeString model.panamaPeriodEndInput )
            , ( "p_period_status", Encode.string model.panamaPeriodStatusInput )
            , ( "p_income_tax_return_due_on", optionalEncodeString model.panamaIncomeTaxDueInput )
            , ( "p_municipal_return_due_on", optionalEncodeString model.panamaMunicipalDueInput )
            , ( "p_period_notes", optionalEncodeString model.panamaPeriodNotesInput )
            ]
        )
        componentListDecoder
        PanamaSettingsSaved


configureTaiwanBusiness : String -> Model -> Cmd Msg
configureTaiwanBusiness bookId model =
    bookRpcInLanguage bookId model.language "configure_taiwan_business"
        (Encode.object
            [ ( "p_book_id", Encode.string bookId )
            , ( "p_legal_name", Encode.string (String.trim model.taiwanLegalNameInput) )
            , ( "p_unified_business_number", Encode.string (String.trim model.taiwanUnifiedBusinessNumberInput) )
            , ( "p_legal_form", Encode.string model.taiwanLegalFormInput )
            , ( "p_business_tax_frequency", Encode.string model.taiwanTaxFrequencyInput )
            , ( "p_uses_uniform_invoices", Encode.bool model.taiwanUsesUniformInvoicesInput )
            , ( "p_enable_manufacturing", Encode.bool model.taiwanManufacturingEnabledInput )
            , ( "p_established_on", optionalEncodeString model.taiwanEstablishedOnInput )
            , ( "p_responsible_person", optionalEncodeString model.taiwanResponsiblePersonInput )
            , ( "p_registered_address", optionalEncodeString model.taiwanRegisteredAddressInput )
            , ( "p_tax_registration_notes", optionalEncodeString model.taiwanTaxRegistrationNotesInput )
            , ( "p_notes", optionalEncodeString model.taiwanNotesInput )
            , ( "p_period_id", Encode.string (String.trim model.taiwanPeriodIdInput) )
            , ( "p_period_start", optionalEncodeString model.taiwanPeriodStartInput )
            , ( "p_period_end", optionalEncodeString model.taiwanPeriodEndInput )
            , ( "p_period_status", Encode.string model.taiwanPeriodStatusInput )
            , ( "p_annual_income_tax_due_on", optionalEncodeString model.taiwanAnnualIncomeTaxDueInput )
            , ( "p_provisional_income_tax_due_on", optionalEncodeString model.taiwanProvisionalIncomeTaxDueInput )
            , ( "p_undistributed_earnings_due_on", optionalEncodeString model.taiwanUndistributedEarningsDueInput )
            , ( "p_period_notes", optionalEncodeString model.taiwanPeriodNotesInput )
            ]
        )
        componentListDecoder
        TaiwanSettingsSaved


createAccount : String -> Model -> Cmd Msg
createAccount bookId model =
    bookRpc bookId "create_account"
        (Encode.object
            [ ( "p_book_id", Encode.string bookId )
            , ( "p_id", Encode.string (String.trim model.accountIdInput) )
            , ( "p_type", Encode.string model.accountTypeInput )
            , ( "p_asset", Encode.string model.accountAssetInput )
            , ( "p_parent_id", optionalEncodeString model.accountParentInput )
            , ( "p_account_kind", Encode.string model.accountKindInput )
            , ( "p_placeholder", Encode.bool model.accountPlaceholderInput )
            , ( "p_pretax", Encode.string model.accountPretaxInput )
            , ( "p_comment", Encode.null )
            , ( "p_opening_balance", optionalEncodeString model.openingBalanceInput )
            , ( "p_opening_date", optionalEncodeString model.openingDateInput )
            ]
        )
        (Decode.list accountDecoder)
        AccountCreated


setPostingReconciled : String -> Int -> String -> Bool -> Cmd Msg
setPostingReconciled bookId xid account reconciled =
    bookRpc bookId "set_posting_reconciled"
        (Encode.object
            [ ( "p_book_id", Encode.string bookId )
            , ( "p_xid", Encode.int xid )
            , ( "p_account_id", Encode.string account )
            , ( "p_reconciled", Encode.bool reconciled )
            ]
        )
        (Decode.list postingReconciliationDecoder)
        PostingReconciled


saveTransaction : String -> Model -> Cmd Msg
saveTransaction bookId model =
    let
        xid =
            case model.committedTransactionXid of
                Just committed ->
                    Just committed

                Nothing ->
                    model.transactionXid
    in
    case xid of
        Nothing ->
            bookRpc bookId "create_transaction"
                (Encode.object
                    [ ( "p_book_id", Encode.string bookId )
                    , ( "p_transaction", encodeTransaction model )
                    ]
                )
                (Decode.list mutationResultDecoder)
                TransactionSaved

        Just targetXid ->
            bookRpc bookId "replace_transaction"
                (Encode.object
                    [ ( "p_book_id", Encode.string bookId )
                    , ( "p_xid", Encode.int targetXid )
                    , ( "p_transaction", encodeTransaction model )
                    ]
                )
                (Decode.list mutationResultDecoder)
                TransactionSaved


encodeTransaction : Model -> Encode.Value
encodeTransaction model =
    Encode.object
        [ ( "date", Encode.string model.transactionDate )
        , ( "comment", Encode.string model.transactionComment )
        , if model.transactionSimple then
            ( "simple", encodeSimpleTransaction model )

          else
            ( "lines", Encode.list encodeDraftLine (submittableDraftLines model) )
        ]


encodeSimpleTransaction : Model -> Encode.Value
encodeSimpleTransaction model =
    let
        primary =
            primaryDraftLine model |> Maybe.withDefault (emptyDraft 0)

        transfer =
            counterpartDraftLines model
                |> List.head
                |> Maybe.withDefault (emptyDraft 0)
    in
    Encode.object
        [ ( "account", Encode.string primary.account )
        , ( "transfer_account", Encode.string transfer.account )
        , ( "amount", Encode.string primary.amount )
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


type ApiTarget
    = ControlApi
    | BookApi String


apiPath : ApiTarget -> String -> String
apiPath target functionName =
    case target of
        ControlApi ->
            "/api/control/rpc/" ++ functionName

        BookApi bookId ->
            "/api/books/" ++ Url.percentEncode bookId ++ "/rpc/" ++ functionName


controlRpc : String -> Encode.Value -> Decoder a -> (Result Http.Error a -> msg) -> Cmd msg
controlRpc functionName body decoder toMsg =
    apiRpcWithTrackerAndHeaders ControlApi [] Nothing functionName body decoder toMsg


bookRpc : String -> String -> Encode.Value -> Decoder a -> (Result Http.Error a -> msg) -> Cmd msg
bookRpc bookId functionName body decoder toMsg =
    apiRpcWithTrackerAndHeaders (BookApi bookId) [] Nothing functionName body decoder toMsg


controlRpcInLanguage : String -> String -> Encode.Value -> Decoder a -> (Result Http.Error a -> msg) -> Cmd msg
controlRpcInLanguage language functionName body decoder toMsg =
    apiRpcWithTrackerAndHeaders
        ControlApi
        [ Http.header "Accept-Language" language ]
        Nothing
        functionName
        body
        decoder
        toMsg


bookRpcInLanguage : String -> String -> String -> Encode.Value -> Decoder a -> (Result Http.Error a -> msg) -> Cmd msg
bookRpcInLanguage bookId language functionName body decoder toMsg =
    apiRpcWithTrackerAndHeaders
        (BookApi bookId)
        [ Http.header "Accept-Language" language ]
        Nothing
        functionName
        body
        decoder
        toMsg


apiRpcWithTrackerAndHeaders : ApiTarget -> List Http.Header -> Maybe String -> String -> Encode.Value -> Decoder a -> (Result Http.Error a -> msg) -> Cmd msg
apiRpcWithTrackerAndHeaders target headers tracker functionName body decoder toMsg =
    Http.request
        { method = "POST"
        , headers = headers
        , url = apiPath target functionName
        , body = Http.jsonBody body
        , expect = expectJsonDetailed toMsg decoder
        , timeout = Just 30000
        , tracker = tracker
        }


view : Model -> Browser.Document Msg
view model =
    { title = presentationText model "app.name"
    , body =
        [ Html.div [ Attr.class "app-shell" ]
            [ viewNavigation model
            , Html.main_ [ Attr.class "page-shell" ] [ viewPage model ]
            ]
        ]
    }


viewNavigation : Model -> Html Msg
viewNavigation model =
    let
        editLocked =
            model.navigationLocked || model.transactionDirty

        activeBook =
            model.selectedBook
                |> Maybe.andThen
                    (\bookId ->
                        model.books
                            |> List.filter (\book -> book.id == bookId)
                            |> List.head
                    )

        canAdminister =
            model.globalAdmin

        globalWorkspace =
            model.page == AdminPage
                || model.page == ShellPage
                || model.page == AddBookPage

        booksRoute =
            { page = ShellPage, book = Nothing, account = Nothing, report = Nothing }

        scopedRoute page =
            case model.selectedBook of
                Just bookId ->
                    { page = page, book = Just bookId, account = Nothing, report = Nothing }

                Nothing ->
                    booksRoute

        scopedLocked =
            editLocked || model.selectedBook == Nothing

        statusText =
            uiStatusText model
    in
    Html.header [ Attr.class "topbar" ]
        [ Html.div [ Attr.class "brand" ] [ Html.h1 [] [ Html.text (presentationText model "app.name") ] ]
        , Html.nav [ Attr.class "workspace-nav", Attr.attribute "aria-label" (presentationText model "nav.primary") ]
            ((if canAdminister then
                [ workspaceLink editLocked (model.page == AdminPage) (presentationText model "nav.admin")
                    { page = AdminPage, book = Nothing, account = Nothing, report = Nothing }
                ]

              else
                []
             )
                ++ [ workspaceLink editLocked (model.page == ShellPage || model.page == AddBookPage || model.page == BookPage) (presentationText model "nav.books")
                        booksRoute
                   ]
                ++ (if globalWorkspace then
                        []

                    else
                        [ workspaceLink scopedLocked (model.page == AccountsPage || model.page == LedgerPage || model.page == AddAccountPage || model.page == ReconciliationPage) (presentationText model "nav.accounts")
                            (scopedRoute AccountsPage)
                        , workspaceLink scopedLocked (model.page == GeneralJournalPage) (presentationText model "nav.journal")
                            (scopedRoute GeneralJournalPage)
                        , workspaceLink scopedLocked (isReportWorkspace model.page) (presentationText model "nav.reports")
                            (scopedRoute ReportsPage)
                        ]
                   )
            )
        , case activeBook of
            Just book ->
                Html.a
                    [ Attr.class "active-book-context"
                    , Attr.href (routeHref { page = ShellPage, book = Nothing, account = Nothing, report = Nothing })
                    , Attr.title (presentationText model "nav.books")
                    ]
                    [ Html.strong [] [ Html.text book.name ]
                    , Html.span [] [ Html.text (" · " ++ book.reportingAsset) ]
                    ]

            Nothing ->
                Html.span [ Attr.class "active-book-context active-book-context-empty" ] []
        , if statusText == "" then
            Html.div [ Attr.class "status-line", Attr.attribute "aria-hidden" "true" ] []

          else
            Html.div
                [ Attr.class "status-line"
                , Attr.attribute "role" "status"
                , Attr.attribute "aria-live" "polite"
                , Attr.attribute "aria-atomic" "true"
                ]
                [ Html.span [ Attr.classList [ ( "busy", model.loading || model.navigationLocked ) ] ] [ Html.text statusText ] ]
        , viewLanguagePicker editLocked model
        ]


viewLanguagePicker : Bool -> Model -> Html Msg
viewLanguagePicker disabled model =
    let
        current =
            model.languageOptions
                |> List.filter (\option -> option.locale == model.language)
                |> List.head

        currentFlag =
            current |> Maybe.map .flag |> Maybe.withDefault "🌐"

        currentLabel =
            current |> Maybe.map .label |> Maybe.withDefault (presentationText model "language.choose")

        menu =
            if model.languageMenuOpen then
                [ Html.div
                    [ Attr.id "language-menu"
                    , Attr.class "language-menu"
                    , Attr.attribute "role" "menu"
                    , Attr.attribute "aria-label" (presentationText model "language.choose")
                    , onLanguageMenuKey
                    ]
                    (List.map (viewLanguageOption model.language) model.languageOptions)
                ]

            else
                []
    in
    Html.div [ Attr.class "language-picker" ]
        (Html.button
            [ Attr.type_ "button"
            , Attr.id "language-trigger"
            , Attr.class "language-trigger"
            , Attr.attribute "aria-label" (presentationText model "language.choose")
            , Attr.attribute "aria-haspopup" "menu"
            , Attr.attribute "aria-expanded" (boolString model.languageMenuOpen)
            , Attr.attribute "aria-controls" "language-menu"
            , Attr.title currentLabel
            , Attr.disabled disabled
            , Events.onClick ToggleLanguageMenu
            ]
            [ Html.text currentFlag ]
            :: menu
        )


viewLanguageOption : String -> LanguageOption -> Html Msg
viewLanguageOption current option =
    Html.button
        [ Attr.type_ "button"
        , Attr.id (languageOptionId option.locale)
        , Attr.class "language-option"
        , Attr.attribute "role" "menuitemradio"
        , Attr.attribute "aria-checked" (boolString (option.locale == current))
        , Attr.attribute "aria-label" option.label
        , Attr.tabindex
            (if option.locale == current then
                0

             else
                -1
            )
        , Attr.title option.label
        , Events.onClick (SelectLanguage option.locale)
        , onLanguageOptionKey option.locale
        ]
        [ Html.text option.flag ]


onLanguageMenuKey : Html.Attribute Msg
onLanguageMenuKey =
    Events.preventDefaultOn "keydown"
        (Decode.field "key" Decode.string
            |> Decode.andThen
                (\key ->
                    if key == "Escape" then
                        Decode.succeed ( CloseLanguageMenu, True )

                    else
                        Decode.fail "ignore key"
                )
        )


onLanguageOptionKey : String -> Html.Attribute Msg
onLanguageOptionKey locale =
    Events.preventDefaultOn "keydown"
        (Decode.field "key" Decode.string
            |> Decode.andThen
                (\key ->
                    case key of
                        "ArrowDown" ->
                            Decode.succeed ( MoveLanguageFocus locale 1, True )

                        "ArrowUp" ->
                            Decode.succeed ( MoveLanguageFocus locale -1, True )

                        _ ->
                            Decode.fail "ignore key"
                )
        )


languageOptionId : String -> String
languageOptionId locale =
    "language-option-" ++ locale


adjacentLanguage : String -> Int -> List LanguageOption -> String
adjacentLanguage locale direction options =
    let
        locales =
            List.map .locale options

        ordered =
            if direction < 0 then
                List.reverse locales

            else
                locales

        neighbours =
            List.map2 Tuple.pair
                ordered
                (List.drop 1 ordered ++ List.take 1 ordered)
    in
    neighbours
        |> List.filter (\( current, _ ) -> current == locale)
        |> List.head
        |> Maybe.map Tuple.second
        |> Maybe.withDefault locale


focusElement : String -> Cmd Msg
focusElement elementId =
    Browser.Dom.focus elementId |> Task.attempt LanguageFocusFinished


optionalEmptyChoice : String -> String -> List ( String, String )
optionalEmptyChoice label current =
    if current == "" then
        [ ( "", label ) ]

    else
        []


selectControl : Bool -> String -> String -> (String -> Msg) -> List ( String, String ) -> Html Msg
selectControl disabled label current toMsg options =
    Html.label [ Attr.class "nav-field" ]
        [ Html.span [] [ Html.text label ]
        , Html.select
            [ Attr.attribute "aria-label" label
            , Attr.value current
            , Attr.disabled disabled
            , Events.onInput toMsg
            ]
            (List.map
                (\( value, text ) ->
                    Html.option [ Attr.value value, Attr.selected (value == current) ] [ Html.text text ]
                )
                options
            )
        ]


workspaceLink : Bool -> Bool -> String -> Route -> Html Msg
workspaceLink locked active label route =
    Html.a
        [ Attr.href (routeHref route)
        , Attr.classList [ ( "workspace-tab", True ), ( "workspace-tab-active", active ) ]
        , Attr.attribute "aria-disabled" (boolString locked)
        , Attr.attribute "aria-current" (if active then "page" else "false")
        ]
        [ Html.text label ]


isReportWorkspace : Page -> Bool
isReportWorkspace page =
    case page of
        ReportsPage -> True
        ReportPage -> True
        _ -> False


viewPage : Model -> Html Msg
viewPage model =
    if model.loading then
        Html.section [ Attr.class "panel loading-panel" ]
            [ Html.text (uiStatusText model) ]

    else
        viewReadyPage model


viewReadyPage : Model -> Html Msg
viewReadyPage model =
    case model.page of
        AdminPage -> viewAdmin model
        BookPage -> viewBook model
        AccountsPage -> viewAccounts model
        LedgerPage -> viewLedger model
        ReportsPage -> viewReports model
        ReportPage -> viewDatabaseReport model
        GeneralJournalPage -> viewJournal model
        ReconciliationPage -> viewReconciliation model
        AddBookPage -> viewAddBook model
        AddAccountPage -> viewAddAccount model
        ShellPage -> viewBooks model


presentationText : Model -> String -> String
presentationText model semanticKey =
    Dict.get semanticKey model.presentation
        |> Maybe.withDefault semanticKey


presentationTextWith : Model -> String -> List ( String, String ) -> String
presentationTextWith model semanticKey replacements =
    List.foldl
        (\( token, value ) text -> String.replace ("{" ++ token ++ "}") value text)
        (presentationText model semanticKey)
        replacements


uiStatusText : Model -> String
uiStatusText model =
    case model.status of
        StatusIdle ->
            ""

        StatusKey semanticKey ->
            Dict.get semanticKey model.presentation |> Maybe.withDefault ""

        StatusTemplate semanticKey replacements ->
            Dict.get semanticKey model.presentation
                |> Maybe.map
                    (\template ->
                        List.foldl
                            (\( token, value ) text -> String.replace ("{" ++ token ++ "}") value text)
                            template
                            replacements
                    )
                |> Maybe.withDefault ""

        StatusText text ->
            text


viewBooks : Model -> Html Msg
viewBooks model =
    Html.section [ Attr.class "panel books-index" ]
        [ sectionHeader (presentationText model "page.books.title")
            (Html.a
                [ Attr.class "secondary-link"
                , Attr.href (routeHref { page = AddBookPage, book = Nothing, account = Nothing, report = Nothing })
                ]
                [ Html.text (presentationText model "option.book.add") ]
            )
        , Html.p [ Attr.class "books-introduction" ]
            [ Html.text
                (if List.isEmpty model.books then
                    presentationText model "page.start.intro"

                 else
                    presentationText model "page.books.intro"
                )
            ]
        , Html.div [ Attr.class "book-card-grid" ] (List.map (viewBookCard model) model.books)
        ]


viewAdmin : Model -> Html Msg
viewAdmin model =
    Html.section [ Attr.class "panel admin-index" ]
        [ sectionHeader (presentationText model "page.admin.title") (Html.text "")
        , Html.p [ Attr.class "admin-introduction" ]
            [ Html.text
                (if List.isEmpty model.globalUsers then
                    presentationText model "page.admin.empty"

                 else
                    presentationText model "page.admin.intro"
                )
            ]
        , Html.div [ Attr.class "settings-card global-users-card" ]
            [ Html.h3 [] [ Html.text (presentationText model "section.admin.users") ]
            , Html.form [ Attr.class "global-user-form", Events.onSubmit SubmitGlobalUser ]
                [ inputField
                    (presentationText model "field.access.github-login")
                    "text"
                    model.globalUserGithubInput
                    UpdateGlobalUserGithub
                , Html.button
                    [ Attr.type_ "submit"
                    , Attr.disabled (String.trim model.globalUserGithubInput == "")
                    ]
                    [ Html.text (presentationText model "action.admin.invite-user") ]
                ]
            , if List.isEmpty model.globalUsers then
                Html.text ""

              else
                Html.div [ Attr.class "table-scroll" ]
                    [ Html.table [ Attr.class "global-users-table" ]
                        [ Html.thead []
                            [ Html.tr []
                                [ Html.th [] [ Html.text (presentationText model "column.user") ]
                                , Html.th [] [ Html.text (presentationText model "column.database-role") ]
                                , Html.th [] [ Html.text (presentationText model "column.status") ]
                                , Html.th [] [ Html.text (presentationText model "column.books") ]
                                , Html.th [] [ Html.text (presentationText model "column.global-admin") ]
                                , Html.th [] [ Html.text (presentationText model "column.actions") ]
                                ]
                            ]
                        , Html.tbody [] (List.map (viewGlobalUser model) model.globalUsers)
                        ]
                    ]
            ]
        ]


viewGlobalUser : Model -> GlobalUser -> Html Msg
viewGlobalUser model user =
    Html.tr [ Attr.classList [ ( "current-global-user", user.currentUser ) ] ]
        [ Html.td []
            [ Html.strong [] [ Html.text user.displayName ]
            , case user.githubLogin of
                Just login ->
                    Html.span [ Attr.class "global-user-login" ] [ Html.text ("@" ++ login) ]

                Nothing ->
                    Html.text ""
            ]
        , Html.td [] [ Html.code [] [ Html.text user.databaseRole ] ]
        , Html.td []
            [ Html.span [ Attr.class ("access-badge access-status-" ++ user.status) ]
                [ Html.text (presentationText model ("state.access." ++ user.status)) ]
            ]
        , Html.td [] [ Html.text (String.fromInt user.bookCount) ]
        , Html.td []
            [ Html.text
                (if user.globalAdmin then
                    presentationText model "access.admin"

                 else
                    "—"
                )
            ]
        , Html.td [ Attr.class "global-user-actions" ]
            (if user.canChangeEnabled then
                [ Html.button
                    [ Attr.type_ "button"
                    , Attr.attribute "data-action-key" user.actionKey
                    , Attr.disabled model.navigationLocked
                    , Events.onClick
                        (SetGlobalUserEnabled
                            user.principalId
                            (not user.enabled)
                            user.actionLabel
                        )
                    ]
                    [ Html.text user.actionLabel ]
                ]

             else
                []
            )
        ]


viewBookCard : Model -> Book -> Html Msg
viewBookCard model book =
    Html.a
        [ Attr.class "book-card"
        , Attr.href
            (routeHref
                { page = BookPage
                , book = Just book.id
                , account = Nothing
                , report = Nothing
                }
            )
        ]
        [ Html.div [ Attr.class "book-card-heading" ]
            [ Html.h3 [] [ Html.text book.name ]
            , Html.span [ Attr.class ("access-badge access-" ++ book.accessLevel) ]
                [ Html.text (presentationText model ("access." ++ book.accessLevel)) ]
            ]
        , Html.p [ Attr.class "book-card-id" ] [ Html.text book.id ]
        , Html.p [ Attr.class "book-card-currency" ] [ Html.text book.reportingAsset ]
        ]


viewBook : Model -> Html Msg
viewBook model =
    let
        identity =
            Maybe.withDefault fallbackBookIdentity model.bookIdentity

        companyEnabled =
            model.companyProfile |> Maybe.map .enabled |> Maybe.withDefault False

        panamaEnabled =
            model.panamaBusinessProfile |> Maybe.map .enabled |> Maybe.withDefault False

        taiwanEnabled =
            model.taiwanBusinessProfile |> Maybe.map .enabled |> Maybe.withDefault False

        vatControlChoices =
            optionalEmptyChoice (presentationText model "option.account.vat-auto") model.companyVatControlInput
                ++ List.map
                    (\account ->
                        ( account.id
                        , if account.path == "" then account.name else account.path
                        )
                    )
                    model.vatControlAccountOptions
    in
    Html.div [ Attr.class "book-workspace" ]
        [ Html.div [ Attr.class "book-workspace-heading" ]
            [ Html.h2 [] [ Html.text (presentationText model "page.book.title") ]
            , viewBookStatus model
            ]
        , viewValidationMessages model.pageValidation
        , viewBookAccess model
        , Html.div [ Attr.class "book-overview-grid" ]
            [ Html.section [ Attr.class "panel book-identity-card" ]
                [ Html.h3 [] [ Html.text (presentationText model "section.book.identity") ]
                , Html.p [ Attr.class "settings-introduction" ]
                    [ Html.text (presentationText model "help.book.identity") ]
                , Html.dl [ Attr.class "definition-grid" ]
                    [ definitionItem (presentationText model "field.book.id") identity.id (presentationText model "note.permanent")
                    , definitionItem (presentationText model "field.book.owner-entity") identity.entityTypeLabel (presentationText model "note.owner-entity")
                    , definitionItem (presentationText model "field.book.current-currency") identity.reportingAsset (presentationText model "note.currency-history")
                    ]
                ]
            , Html.section [ Attr.class "panel configuration-card" ]
                [ Html.h3 [] [ Html.text (presentationText model "section.book.configuration") ]
                , if List.isEmpty model.configurationChecks then
                    Html.p [ Attr.class "settings-introduction" ]
                        [ Html.text
                            (if identity.entityType == "household" then
                                presentationText model "help.book.no-pack-household"

                             else
                                presentationText model "help.book.no-pack"
                            )
                        ]

                  else
                    Html.ul [ Attr.class "configuration-checks" ]
                        (List.map (viewConfigurationCheck (companyEnabled || panamaEnabled || taiwanEnabled)) model.configurationChecks)
                ]
            ]
        , Html.section [ Attr.class "panel book-settings-card" ]
            [ Html.h3 [] [ Html.text (presentationText model "section.book.details") ]
            , Html.p [ Attr.class "settings-introduction" ]
                [ Html.text (presentationText model "help.book.details") ]
            , Html.form [ Attr.class "book-name-form", Events.onSubmit SubmitBookSettings ]
                [ inputField (presentationText model "field.book.name") "text" model.bookSettingsNameInput UpdateBookSettingsName
                , choicePairsField (presentationText model "field.book.owner-entity") model.bookSettingsEntityTypeInput UpdateBookSettingsEntityType
                    (namedOptionPairs model.bookEntityTypeOptions)
                    False
                , Html.button [ Attr.type_ "submit" ] [ Html.text (presentationText model "action.book.save") ]
                ]
            ]
        , Html.section [ Attr.class "panel reporting-currency-card" ]
            [ Html.h3 [] [ Html.text (presentationText model "section.book.currency") ]
            , Html.p [ Attr.class "settings-introduction" ]
                [ Html.text (presentationText model "help.book.currency") ]
            , Html.form [ Attr.class "book-currency-form", Events.onSubmit SubmitBookCurrency ]
                [ choiceField (presentationText model "field.book.currency") model.bookCurrencyInput UpdateBookCurrency model.assets
                , inputField (presentationText model "field.book.currency-effective-date") "date" model.bookCurrencyEffectiveFromInput UpdateBookCurrencyEffectiveFrom
                , Html.button
                    [ Attr.type_ "submit"
                    , Attr.disabled (model.bookCurrencyInput == "")
                    ]
                    [ Html.text (presentationText model "action.book.currency-update") ]
                ]
            , Html.ul [ Attr.class "currency-history" ]
                (List.map (viewReportingCurrency model) model.reportingCurrencies)
            ]
        , Html.section [ Attr.class "panel book-lifecycle-card" ]
            [ Html.h3 [] [ Html.text (presentationText model "section.book.lifecycle") ]
            , case identity.archivedAt of
                Nothing ->
                    Html.div [ Attr.class "lifecycle-actions" ]
                        [ Html.p [ Attr.class "settings-introduction" ]
                            [ Html.text (presentationText model "help.book.archive") ]
                        , Html.button [ Attr.type_ "button", Events.onClick ArchiveBook ] [ Html.text (presentationText model "action.book.archive") ]
                        ]

                Just archivedAt ->
                    Html.div [ Attr.class "archived-book-controls" ]
                        [ Html.p [ Attr.class "settings-introduction" ]
                            [ Html.text (presentationTextWith model "help.book.archived" [ ( "date", archivedAt ) ]) ]
                        , Html.div [ Attr.class "lifecycle-actions" ]
                            [ Html.button [ Attr.type_ "button", Events.onClick RestoreBook ] [ Html.text (presentationText model "action.book.restore") ]
                            ]
                        , Html.div [ Attr.class "delete-book-confirmation" ]
                            [ inputField (presentationTextWith model "help.book.delete-confirmation" [ ( "name", identity.name ) ]) "text" model.bookDeleteConfirmationInput UpdateBookDeleteConfirmation
                            , Html.button
                                [ Attr.type_ "button"
                                , Attr.class "danger-button"
                                , Attr.disabled (model.bookDeleteConfirmationInput /= identity.name)
                                , Events.onClick DeleteBook
                                ]
                                [ Html.text (presentationText model "action.book.delete") ]
                            ]
                        ]
            ]
        , case model.companyProfile of
            Nothing ->
                Html.text ""

            Just _ ->
                Html.section [ Attr.class "panel uk-company-card" ]
                    [ Html.div [ Attr.class "settings-section-heading" ]
                        [ Html.div []
                            [ Html.h3 [] [ Html.text (presentationText model "section.uk-company") ]
                            , Html.p [ Attr.class "settings-introduction" ]
                                [ Html.text
                                    (if companyEnabled then
                                        presentationText model "help.uk-company.enabled"

                                     else
                                        presentationText model "help.uk-company.disabled"
                                    )
                                ]
                            ]
                        , Html.span [ Attr.class "settings-scope-note" ] [ Html.text (presentationText model "state.one-accounting-period") ]
                        ]
                    , Html.form [ Attr.class "company-settings-form", Events.onSubmit SubmitCompanySettings ]
                        [ settingsGroup (presentationText model "group.company.identity")
                            [ inputField (presentationText model "field.legal-name") "text" model.companyLegalNameInput UpdateCompanyLegalName
                            , inputField (presentationText model "field.company-number") "text" model.companyNumberInput UpdateCompanyNumber
                            , choicePairsField (presentationText model "field.legal-form") model.companyLegalFormInput UpdateCompanyLegalForm
                                (namedOptionPairs model.legalFormOptions)
                                False
                            , choicePairsField (presentationText model "field.accounting-framework") model.companyFrameworkInput UpdateCompanyFramework
                                (namedOptionPairs model.accountingFrameworkOptions)
                                False
                            , inputField (presentationText model "field.incorporation-date") "date" model.companyIncorporatedOnInput UpdateCompanyIncorporatedOn
                            , textareaField (presentationText model "field.registered-office") model.companyRegisteredOfficeInput UpdateCompanyRegisteredOffice
                            ]
                        , settingsGroup (presentationText model "group.hmrc-vat")
                            [ inputField (presentationText model "field.utr") "text" model.companyUtrInput UpdateCompanyUtr
                            , inputField (presentationText model "field.vat-registration-number") "text" model.companyVatRegistrationInput UpdateCompanyVatRegistration
                            , choicePairsField (presentationText model "field.vat-scheme") model.companyVatSchemeInput UpdateCompanyVatScheme
                                (namedOptionPairs model.vatSchemeOptions)
                                False
                            , choicePairsField (presentationText model "field.vat-control-account") model.companyVatControlInput UpdateCompanyVatControl
                                vatControlChoices
                                (model.companyVatSchemeInput == "not_registered")
                            ]
                        , settingsGroup (presentationText model "group.accounting.period")
                            [ if companyEnabled then
                                readOnlyInputField
                                    (presentationText model "field.period.id")
                                    model.companyPeriodIdInput
                                    (presentationText model "note.period-id-company")

                              else
                                inputField (presentationText model "field.period.id") "text" model.companyPeriodIdInput UpdateCompanyPeriodId
                            , inputField (presentationText model "field.period.start") "date" model.companyPeriodStartInput UpdateCompanyPeriodStart
                            , inputField (presentationText model "field.period.end") "date" model.companyPeriodEndInput UpdateCompanyPeriodEnd
                            , choicePairsField (presentationText model "field.period.status") model.companyPeriodStatusInput UpdateCompanyPeriodStatus
                                (namedOptionPairs model.periodStatusOptions)
                                False
                            , inputField (presentationText model "field.accounts-due") "date" model.companyAccountsDueInput UpdateCompanyAccountsDue
                            , inputField (presentationText model "field.corporation-tax-due") "date" model.companyCorporationTaxDueInput UpdateCompanyCorporationTaxDue
                            , inputField (presentationText model "field.accounts-filed") "date" model.companyAccountsFiledInput UpdateCompanyAccountsFiled
                            , inputField (presentationText model "field.ct600-filed") "date" model.companyCt600FiledInput UpdateCompanyCt600Filed
                            ]
                        , settingsGroup (presentationText model "group.notes.additional")
                            [ textareaField (presentationText model "field.company-notes") model.companyNotesInput UpdateCompanyNotes
                            , textareaField (presentationText model "field.period-notes") model.companyPeriodNotesInput UpdateCompanyPeriodNotes
                            ]
                        , Html.div [ Attr.class "company-form-actions" ]
                            [ Html.p [] [ Html.text (presentationText model "help.uk-company.ledger-source") ]
                            , Html.button [ Attr.type_ "submit" ] [ Html.text (presentationText model "action.uk-company.save") ]
                            ]
                        ]
                        ]
        , case model.panamaBusinessProfile of
            Nothing ->
                Html.text ""

            Just panamaProfile ->
                viewPanamaBusinessSettings model panamaProfile
        , case model.taiwanBusinessProfile of
            Nothing ->
                Html.text ""

            Just taiwanProfile ->
                viewTaiwanBusinessSettings model taiwanProfile
        ]


viewBookAccess : Model -> Html Msg
viewBookAccess model =
    if List.isEmpty model.bookAccessLevelOptions then
        Html.text ""

    else
      Html.section [ Attr.class "panel book-access-card" ]
        [ Html.h3 [] [ Html.text (presentationText model "section.book.access") ]
        , Html.p [ Attr.class "settings-introduction" ]
            [ Html.text (presentationText model "section.book.access-intro") ]
        , Html.form [ Attr.class "book-access-form", Events.onSubmit SubmitBookAccess ]
            [ inputField (presentationText model "field.access.github-login") "text" model.bookAccessGithubInput UpdateBookAccessGithub
            , choicePairsField (presentationText model "field.access.level") model.bookAccessLevelInput UpdateBookAccessLevel
                (namedOptionPairs model.bookAccessLevelOptions)
                False
            , Html.button
                [ Attr.type_ "submit"
                , Attr.disabled (String.trim model.bookAccessGithubInput == "")
                ]
                [ Html.text (presentationText model "action.access.add") ]
            ]
        , Html.table [ Attr.class "data-table book-access-table" ]
            [ Html.thead []
                [ Html.tr []
                    [ Html.th [] [ Html.text (presentationText model "column.user") ]
                    , Html.th [] [ Html.text (presentationText model "field.access.level") ]
                    , Html.th [] [ Html.text (presentationText model "column.status") ]
                    , Html.th [ Attr.class "book-access-actions" ] []
                    ]
                ]
            , Html.tbody [] (List.map (viewBookAccessRow model) model.bookAccess)
            ]
        ]


viewBookAccessRow : Model -> BookAccess -> Html Msg
viewBookAccessRow model access =
    Html.tr [ Attr.attribute "data-principal-id" access.principalId ]
        [ Html.td []
            [ Html.strong [] [ Html.text access.displayName ]
            , Html.small [ Attr.class "book-access-login" ]
                [ Html.text ("@" ++ Maybe.withDefault access.databaseRole access.githubLogin) ]
            ]
        , Html.td []
            [ if access.currentUser then
                Html.span [ Attr.class ("access-badge access-" ++ access.accessLevel) ]
                    [ Html.text (presentationText model ("access." ++ access.accessLevel)) ]

              else
                Html.select
                    [ Attr.attribute "aria-label" (presentationText model "field.access.level" ++ " — " ++ access.displayName)
                    , Attr.value access.accessLevel
                    , Attr.disabled model.navigationLocked
                    , Events.onInput (ChangeBookAccess access.principalId)
                    ]
                    (List.map
                        (\option ->
                            Html.option
                                [ Attr.value option.id, Attr.selected (option.id == access.accessLevel) ]
                                [ Html.text option.label ]
                        )
                        model.bookAccessLevelOptions
                    )
            ]
        , Html.td []
            [ Html.text (presentationText model ("state.access." ++ access.status)) ]
        , Html.td [ Attr.class "book-access-actions" ]
            [ if access.currentUser then
                Html.text ""

              else
                Html.button
                    [ Attr.type_ "button"
                    , Attr.class "text-danger-button"
                    , Attr.disabled model.navigationLocked
                    , Events.onClick (RemoveBookAccess access.principalId)
                    ]
                    [ Html.text (presentationText model "action.access.remove") ]
            ]
        ]


viewPanamaBusinessSettings : Model -> PanamaBusinessProfile -> Html Msg
viewPanamaBusinessSettings model profile =
    Html.section [ Attr.class "panel panama-business-card" ]
        [ Html.div [ Attr.class "settings-section-heading" ]
            [ Html.div []
                [ Html.h3 [] [ Html.text (presentationText model "section.panama-business") ]
                , Html.p [ Attr.class "settings-introduction" ]
                    [ Html.text
                        (if profile.enabled then
                            presentationText model "help.panama-business.enabled"

                         else
                            presentationText model "help.panama-business.disabled"
                        )
                    ]
                ]
            , Html.span [ Attr.class "settings-scope-note" ]
                [ Html.text
                    (if profile.residentialPropertyEnabled then
                        presentationTextWith model "summary.panama.properties"
                            [ ( "count", String.fromInt profile.propertyCount ) ]

                     else
                        presentationText model "state.generic-business"
                    )
                ]
            ]
        , Html.form [ Attr.class "company-settings-form", Events.onSubmit SubmitPanamaSettings ]
            [ settingsGroup (presentationText model "group.business.identity")
                [ inputField (presentationText model "field.legal-name") "text" model.panamaLegalNameInput UpdatePanamaLegalName
                , inputField (presentationText model "field.ruc") "text" model.panamaRucInput UpdatePanamaRuc
                , inputField (presentationText model "field.verification-digit") "text" model.panamaVerificationDigitInput UpdatePanamaVerificationDigit
                , choicePairsField (presentationText model "field.legal-form") model.panamaLegalFormInput UpdatePanamaLegalForm
                    (namedOptionPairs model.panamaLegalFormOptions)
                    False
                , choicePairsField (presentationText model "field.municipality") model.panamaMunicipalityInput UpdatePanamaMunicipality
                    (namedOptionPairs model.panamaMunicipalityOptions)
                    False
                , inputField (presentationText model "field.incorporation-date") "date" model.panamaIncorporatedOnInput UpdatePanamaIncorporatedOn
                , inputField (presentationText model "field.resident-agent") "text" model.panamaResidentAgentInput UpdatePanamaResidentAgent
                , inputField (presentationText model "field.operations-notice") "text" model.panamaOperationsNoticeInput UpdatePanamaOperationsNotice
                , textareaField (presentationText model "field.registered-address") model.panamaRegisteredAddressInput UpdatePanamaRegisteredAddress
                ]
            , settingsGroup (presentationText model "group.accounting.scope")
                [ Html.label [ Attr.class "checkbox-field" ]
                    [ Html.input
                        [ Attr.type_ "checkbox"
                        , Attr.checked model.panamaItbmsRegisteredInput
                        , Events.onCheck UpdatePanamaItbmsRegistered
                        ]
                        []
                    , Html.span [] [ Html.text (presentationText model "field.itbms-registered") ]
                    ]
                , Html.label [ Attr.class "checkbox-field" ]
                    [ Html.input
                        [ Attr.type_ "checkbox"
                        , Attr.checked model.panamaLodgingActivityInput
                        , Events.onCheck UpdatePanamaLodgingActivity
                        ]
                        []
                    , Html.span [] [ Html.text (presentationText model "field.lodging-activity") ]
                    ]
                , Html.label [ Attr.class "checkbox-field" ]
                    [ Html.input
                        [ Attr.type_ "checkbox"
                        , Attr.checked model.panamaPropertyEnabledInput
                        , Events.onCheck UpdatePanamaPropertyEnabled
                        ]
                        []
                    , Html.span []
                        [ Html.text (presentationText model "field.residential-property-enabled") ]
                    ]
                ]
            , settingsGroup (presentationText model "group.fiscal.period")
                [ if profile.enabled then
                    readOnlyInputField
                        (presentationText model "field.period.id")
                        model.panamaPeriodIdInput
                        (presentationText model "note.period-id")

                  else
                    inputField (presentationText model "field.period.id") "text" model.panamaPeriodIdInput UpdatePanamaPeriodId
                , inputField (presentationText model "field.period.start") "date" model.panamaPeriodStartInput UpdatePanamaPeriodStart
                , inputField (presentationText model "field.period.end") "date" model.panamaPeriodEndInput UpdatePanamaPeriodEnd
                , choicePairsField (presentationText model "field.period.status") model.panamaPeriodStatusInput UpdatePanamaPeriodStatus
                    (namedOptionPairs model.panamaPeriodStatusOptions)
                    False
                , inputField (presentationText model "field.income-tax-return-due") "date" model.panamaIncomeTaxDueInput UpdatePanamaIncomeTaxDue
                , inputField (presentationText model "field.municipal-return-due") "date" model.panamaMunicipalDueInput UpdatePanamaMunicipalDue
                ]
            , settingsGroup (presentationText model "group.notes")
                [ textareaField (presentationText model "field.business-notes") model.panamaNotesInput UpdatePanamaNotes
                , textareaField (presentationText model "field.period-notes") model.panamaPeriodNotesInput UpdatePanamaPeriodNotes
                ]
            , Html.div [ Attr.class "company-form-actions" ]
                [ Html.p []
                    [ Html.text (presentationText model "help.panama-business.disclaimer") ]
                , Html.button [ Attr.type_ "submit" ]
                    [ Html.text (presentationText model "action.panama-business.save") ]
                ]
            ]
        ]


viewTaiwanBusinessSettings : Model -> TaiwanBusinessProfile -> Html Msg
viewTaiwanBusinessSettings model profile =
    Html.section [ Attr.class "panel taiwan-business-card" ]
        [ Html.div [ Attr.class "settings-section-heading" ]
            [ Html.div []
                [ Html.h3 [] [ Html.text (presentationText model "section.taiwan-business") ]
                , Html.p [ Attr.class "settings-introduction" ]
                    [ Html.text
                        (if profile.enabled then
                            presentationText model "help.taiwan-business.enabled"

                         else
                            presentationText model "help.taiwan-business.disabled"
                        )
                    ]
                ]
            , Html.span [ Attr.class "settings-scope-note" ]
                [ Html.text
                    (if profile.manufacturingEnabled then
                        presentationTextWith model "summary.taiwan.manufacturing"
                            [ ( "count", String.fromInt profile.inventoryItemCount ) ]

                     else
                        presentationText model "state.generic-business"
                    )
                ]
            ]
        , Html.form [ Attr.class "company-settings-form", Events.onSubmit SubmitTaiwanSettings ]
            [ settingsGroup (presentationText model "group.business.identity")
                [ inputField (presentationText model "field.legal-name") "text" model.taiwanLegalNameInput UpdateTaiwanLegalName
                , inputField (presentationText model "field.unified-business-number") "text" model.taiwanUnifiedBusinessNumberInput UpdateTaiwanUnifiedBusinessNumber
                , choicePairsField (presentationText model "field.legal-form") model.taiwanLegalFormInput UpdateTaiwanLegalForm
                    (namedOptionPairs model.taiwanLegalFormOptions)
                    False
                , inputField (presentationText model "field.established-on") "date" model.taiwanEstablishedOnInput UpdateTaiwanEstablishedOn
                , inputField (presentationText model "field.responsible-person") "text" model.taiwanResponsiblePersonInput UpdateTaiwanResponsiblePerson
                , textareaField (presentationText model "field.registered-address") model.taiwanRegisteredAddressInput UpdateTaiwanRegisteredAddress
                ]
            , settingsGroup (presentationText model "group.accounting.scope")
                [ choicePairsField (presentationText model "field.business-tax-frequency") model.taiwanTaxFrequencyInput UpdateTaiwanTaxFrequency
                    (namedOptionPairs model.taiwanTaxFrequencyOptions)
                    False
                , Html.label [ Attr.class "checkbox-field" ]
                    [ Html.input
                        [ Attr.type_ "checkbox"
                        , Attr.checked model.taiwanUsesUniformInvoicesInput
                        , Events.onCheck UpdateTaiwanUsesUniformInvoices
                        ]
                        []
                    , Html.span [] [ Html.text (presentationText model "field.uniform-invoices") ]
                    ]
                , Html.label [ Attr.class "checkbox-field" ]
                    [ Html.input
                        [ Attr.type_ "checkbox"
                        , Attr.checked model.taiwanManufacturingEnabledInput
                        , Events.onCheck UpdateTaiwanManufacturingEnabled
                        ]
                        []
                    , Html.span [] [ Html.text (presentationText model "field.injection-moulding-enabled") ]
                    ]
                , textareaField (presentationText model "field.tax-registration-notes") model.taiwanTaxRegistrationNotesInput UpdateTaiwanTaxRegistrationNotes
                ]
            , settingsGroup (presentationText model "group.fiscal.period")
                [ if profile.enabled then
                    readOnlyInputField
                        (presentationText model "field.period.id")
                        model.taiwanPeriodIdInput
                        (presentationText model "note.period-id")

                  else
                    inputField (presentationText model "field.period.id") "text" model.taiwanPeriodIdInput UpdateTaiwanPeriodId
                , inputField (presentationText model "field.period.start") "date" model.taiwanPeriodStartInput UpdateTaiwanPeriodStart
                , inputField (presentationText model "field.period.end") "date" model.taiwanPeriodEndInput UpdateTaiwanPeriodEnd
                , choicePairsField (presentationText model "field.period.status") model.taiwanPeriodStatusInput UpdateTaiwanPeriodStatus
                    (namedOptionPairs model.taiwanPeriodStatusOptions)
                    False
                , inputField (presentationText model "field.annual-income-tax-due") "date" model.taiwanAnnualIncomeTaxDueInput UpdateTaiwanAnnualIncomeTaxDue
                , inputField (presentationText model "field.provisional-income-tax-due") "date" model.taiwanProvisionalIncomeTaxDueInput UpdateTaiwanProvisionalIncomeTaxDue
                , inputField (presentationText model "field.undistributed-earnings-due") "date" model.taiwanUndistributedEarningsDueInput UpdateTaiwanUndistributedEarningsDue
                ]
            , settingsGroup (presentationText model "group.notes")
                [ textareaField (presentationText model "field.business-notes") model.taiwanNotesInput UpdateTaiwanNotes
                , textareaField (presentationText model "field.period-notes") model.taiwanPeriodNotesInput UpdateTaiwanPeriodNotes
                ]
            , Html.div [ Attr.class "company-form-actions" ]
                [ Html.p []
                    [ Html.text (presentationText model "help.taiwan-business.disclaimer") ]
                , Html.button [ Attr.type_ "submit" ]
                    [ Html.text (presentationText model "action.taiwan-business.save") ]
                ]
            ]
        ]


viewBookStatus : Model -> Html Msg
viewBookStatus model =
    let
        identity =
            Maybe.withDefault fallbackBookIdentity model.bookIdentity

        panamaProfile =
            model.panamaBusinessProfile

        taiwanProfile =
            model.taiwanBusinessProfile

        ( label, modifier ) =
            if identity.archivedAt /= Nothing then
                ( presentationText model "state.archived", "configuration-status-incomplete" )

            else
                case panamaProfile of
                    Just profile ->
                        if profile.enabled && profile.residentialPropertyEnabled && profile.propertyCount > 0 then
                            ( presentationText model "state.panama-property-pack", "configuration-status-complete" )

                        else if profile.enabled then
                            ( presentationText model "state.panama-business", "configuration-status-complete" )

                        else
                            ( identity.entityTypeLabel, "configuration-status-ordinary" )

                    Nothing ->
                        case taiwanProfile of
                            Just profile ->
                                if profile.enabled && profile.manufacturingEnabled then
                                    ( presentationText model "state.taiwan-manufacturing", "configuration-status-complete" )

                                else if profile.enabled then
                                    ( presentationText model "state.taiwan-business", "configuration-status-complete" )

                                else
                                    ( identity.entityTypeLabel, "configuration-status-ordinary" )

                            Nothing ->
                                case model.bookConfigurationStatus of
                                    "complete" ->
                                        ( presentationText model "state.uk-company-ready", "configuration-status-complete" )

                                    "incomplete" ->
                                        ( presentationText model "state.uk-company-setup", "configuration-status-incomplete" )

                                    _ ->
                                        ( identity.entityTypeLabel, "configuration-status-ordinary" )
    in
    Html.span [ Attr.classList [ ( "configuration-status", True ), ( modifier, True ) ] ] [ Html.text label ]


viewReportingCurrency : Model -> ReportingCurrency -> Html Msg
viewReportingCurrency model currency =
    let
        start =
            if currency.effectiveFrom == "-infinity" then
                presentationText model "state.from-beginning"

            else
                presentationTextWith model "state.from-date" [ ( "date", currency.effectiveFrom ) ]
    in
    Html.li [ Attr.classList [ ( "currency-history-row", True ), ( "currency-history-current", currency.current ) ] ]
        [ Html.strong [] [ Html.text currency.asset ]
        , Html.span [] [ Html.text start ]
        , if currency.current then
            Html.span [ Attr.class "currency-current-label" ] [ Html.text (presentationText model "state.current") ]

          else
            Html.text ""
        ]


definitionItem : String -> String -> String -> Html Msg
definitionItem label value note =
    Html.div [ Attr.class "definition-item" ]
        [ Html.dt [] [ Html.text label ]
        , Html.dd []
            [ Html.strong [] [ Html.text value ]
            , Html.span [] [ Html.text note ]
            ]
        ]


viewConfigurationCheck : Bool -> ConfigurationCheck -> Html Msg
viewConfigurationCheck companyEnabled check =
    Html.li
        [ Attr.classList
            [ ( "configuration-check", True )
            , ( "configuration-check-complete", check.complete )
            , ( "configuration-check-optional", not companyEnabled )
            ]
        ]
        [ Html.span [ Attr.class "configuration-check-mark", Attr.attribute "aria-hidden" "true" ]
            [ Html.text
                (if check.complete then
                    "✓"

                 else if companyEnabled then
                    "!"

                 else
                    "·"
                )
            ]
        , Html.span []
            [ Html.strong [] [ Html.text check.label ]
            , Html.span [] [ Html.text check.message ]
            ]
        ]


namedOptionPairs : List NamedOption -> List ( String, String )
namedOptionPairs options =
    List.map (\option -> ( option.id, option.label )) options


settingsGroup : String -> List (Html Msg) -> Html Msg
settingsGroup title fields =
    Html.fieldset [ Attr.class "settings-group" ]
        [ Html.legend [] [ Html.text title ]
        , Html.div [ Attr.class "settings-grid" ] fields
        ]


viewAccounts : Model -> Html Msg
viewAccounts model =
    Html.section [ Attr.class "panel accounts-index" ]
        [ sectionHeader (presentationText model "page.accounts.title")
            (Html.div [ Attr.class "accounts-page-actions" ]
                [ Html.a
                    [ Attr.class "secondary-link"
                    , Attr.href
                        (routeHref
                            { page = ReconciliationPage
                            , book = model.selectedBook
                            , account = Nothing
                            , report = Nothing
                            }
                        )
                    ]
                    [ Html.text (presentationText model "action.reconcile") ]
                , Html.a
                    [ Attr.class "secondary-link"
                    , Attr.href
                        (routeHref
                            { page = AddAccountPage
                            , book = model.selectedBook
                            , account = Nothing
                            , report = Nothing
                            }
                        )
                    ]
                    [ Html.text (presentationText model "option.account.add") ]
                ]
            )
        , viewValidationMessages model.pageValidation
        , Html.p [ Attr.class "accounts-introduction" ]
            [ Html.text (presentationText model "page.accounts.intro") ]
        , if List.isEmpty model.accountSummaries then
            Html.p [ Attr.class "muted-cell" ] [ Html.text (presentationText model "page.accounts.empty") ]

          else
            Html.table [ Attr.class "data-table accounts-table" ]
                [ Html.thead []
                    [ Html.tr []
                        [ Html.th [] [ Html.text (presentationText model "column.account") ]
                        , Html.th [] [ Html.text (presentationText model "column.commodity") ]
                        , Html.th [ Attr.class "number" ] [ Html.text (presentationText model "column.native-balance") ]
                        , Html.th [ Attr.class "number" ] [ Html.text (presentationText model "column.reporting-market-value") ]
                        , Html.th [ Attr.class "number" ] [ Html.text (presentationText model "column.postings") ]
                        , Html.th [ Attr.class "number" ] [ Html.text (presentationText model "column.unreconciled") ]
                        ]
                    ]
                , Html.tbody []
                    (model.accountSummaries
                        |> List.filter (accountSummaryVisible model)
                        |> List.map (viewAccountSummary model)
                    )
                ]
        ]


accountSummaryVisible : Model -> AccountSummary -> Bool
accountSummaryVisible model account =
    not (List.any (\ancestor -> List.member ancestor model.collapsedAccounts) account.ancestorIds)


viewAccountSummary : Model -> AccountSummary -> Html Msg
viewAccountSummary model account =
    let
        expanded =
            not (List.member account.id model.collapsedAccounts)

        displayedNativeBalance =
            if account.hasChildren then
                if account.subtreeBalanceComplete then
                    Just account.subtreeBalance

                else
                    Nothing

            else
                Just account.balance

        accountName =
            if account.placeholder then
                Html.span [ Attr.class "account-name account-placeholder-name" ] [ Html.text account.name ]

            else
                Html.a
                    [ Attr.class "account-link account-name"
                    , Attr.href
                        (routeHref
                            { page = LedgerPage
                            , book = model.selectedBook
                            , account = Just account.id
                            , report = Nothing
                            }
                        )
                    , Attr.title (presentationTextWith model "aria.account.open-register" [ ( "account", account.path ) ])
                    ]
                    [ Html.text account.name ]
    in
    Html.tr
        [ Attr.classList
            [ ( "account-tree-row", True )
            , ( "account-placeholder-row", account.placeholder )
            ]
        , Attr.attribute "data-account-id" account.id
        , Attr.attribute "data-account-path" account.path
        , Attr.attribute "data-depth" (String.fromInt account.depth)
        , Attr.attribute "data-placeholder" (boolString account.placeholder)
        ]
        [ Html.td [ Attr.class "account-tree-cell" ]
            [ Html.div
                [ Attr.class "account-tree-entry"
                , Attr.style "padding-left" (String.fromFloat (toFloat account.depth * 2.5) ++ "rem")
                ]
                [ if account.hasChildren then
                    Html.button
                        [ Attr.type_ "button"
                        , Attr.class "account-disclosure"
                        , Attr.attribute "aria-label"
                            (presentationTextWith model
                                (if expanded then "aria.account.collapse" else "aria.account.expand")
                                [ ( "account", account.name ) ]
                            )
                        , Attr.attribute "aria-expanded" (boolString expanded)
                        , Events.onClick (ToggleAccountTree account.id)
                        ]
                        [ Html.span [ Attr.attribute "aria-hidden" "true" ]
                            [ Html.text (if expanded then "▾" else "▸") ]
                        ]

                  else
                    Html.span [ Attr.class "account-disclosure-spacer", Attr.attribute "aria-hidden" "true" ] []
                , accountName
                , Html.span [ Attr.class "account-kind" ] [ Html.text (accountKindLabel model account.accountKind) ]
                , if account.isCashAccount then
                    Html.span [ Attr.class "account-tag" ] [ Html.text (presentationText model "state.cash") ]

                  else
                    Html.text ""
                , Html.a
                    [ Attr.class "add-subaccount-link"
                    , Attr.href
                        (routeHref
                            { page = AddAccountPage
                            , book = model.selectedBook
                            , account = Just account.id
                            , report = Nothing
                            }
                        )
                    , Attr.attribute "aria-label" (presentationTextWith model "aria.account.add-subaccount" [ ( "account", account.name ) ])
                    ]
                    [ Html.text (presentationText model "action.account.add-subaccount") ]
                ]
            ]
        , Html.td [] [ Html.text account.asset ]
        , Html.td [ Attr.class "number account-native-balance" ]
            [ case displayedNativeBalance of
                Just value ->
                    Html.span [] [ Html.text (value ++ " " ++ account.asset) ]

                Nothing ->
                    Html.span
                        [ Attr.class "muted-cell"
                        , Attr.title (presentationText model "aria.account.mixed-commodity")
                        ]
                        [ Html.text "—" ]
            , if account.hasChildren && decimalHasMagnitude account.balance then
                Html.small [ Attr.class "account-own-balance" ]
                    [ Html.text
                        (presentationTextWith model "label.account.own"
                            [ ( "value", account.balance ), ( "asset", account.asset ) ]
                        )
                    ]

              else
                Html.text ""
            ]
        , Html.td [ Attr.class "number account-reporting-value" ]
            [ case account.reportingValue of
                Just value ->
                    Html.text
                        (String.trim
                            (value ++ " " ++ Maybe.withDefault "" account.reportingAsset)
                        )

                Nothing ->
                    Html.span [ Attr.class "muted-cell" ] [ Html.text "—" ]
            ]
        , Html.td [ Attr.class "number" ] [ Html.text (String.fromInt account.postingCount) ]
        , Html.td [ Attr.class "number" ]
            [ if account.placeholder then
                Html.text (String.fromInt account.unreconciledCount)

              else
                Html.a
                    [ Attr.class "reconciliation-link"
                    , Attr.href
                        (routeHref
                            { page = ReconciliationPage
                            , book = model.selectedBook
                            , account = Just account.id
                            , report = Nothing
                            }
                        )
                    , Attr.title (presentationText model "action.reconcile" ++ " — " ++ account.name)
                    ]
                    [ Html.text (String.fromInt account.unreconciledCount) ]
            ]
        ]


accountKindLabel : Model -> String -> String
accountKindLabel model accountKind =
    model.accountKindOptions
        |> List.filter (\option -> option.id == accountKind)
        |> List.head
        |> Maybe.map .label
        |> Maybe.withDefault (String.replace "_" " " accountKind)


viewLedger : Model -> Html Msg
viewLedger model =
    Html.section
        [ Attr.class "panel ledger-panel"
        , Attr.attribute "aria-busy" (boolString (model.ledgerSync /= LedgerIdle))
        , Attr.attribute "data-ledger-sync" (ledgerSyncLabel model.ledgerSync)
        ]
        [ sectionHeader (presentationText model "page.ledger.title") (viewAccountContext model)
        , viewValidationMessages model.pageValidation
        , Html.table [ Attr.class "ledger-table ledger-register" ]
            [ Html.thead []
                [ Html.tr []
                    [ Html.th [ Attr.class "ledger-date" ] [ Html.text (presentationText model "field.transaction.date") ]
                    , Html.th [ Attr.class "ledger-description" ] [ Html.text (presentationText model "field.transaction.description") ]
                    , Html.th [ Attr.class "ledger-transfer" ] [ Html.text (presentationText model "field.transaction.transfer") ]
                    , Html.th [ Attr.class "number ledger-deposit" ] [ Html.text (presentationText model "field.transaction.deposit") ]
                    , Html.th [ Attr.class "number ledger-withdrawal" ] [ Html.text (presentationText model "field.transaction.withdrawal") ]
                    , Html.th [ Attr.class "number ledger-balance" ] [ Html.text (presentationText model "field.transaction.balance") ]
                    ]
                ]
            , Keyed.node "tbody" [] (List.concatMap (viewKeyedLedgerEntry model) model.ledger)
            , Html.tfoot [] (viewAppendRows model)
            ]
        ]


viewAccountContext : Model -> Html Msg
viewAccountContext model =
    let
        current =
            Maybe.withDefault "" model.selectedAccount
    in
    Html.div [ Attr.class "account-context" ]
        [ selectControl (model.navigationLocked || model.transactionDirty) (presentationText model "column.account") current SelectAccount
            (optionalEmptyChoice (presentationText model "option.account.select") current
                ++ List.map (\account -> ( account.id, account.id )) model.accounts
                ++ [ ( addAccountValue, presentationText model "option.account.add" ) ]
            )
        ]


viewKeyedLedgerEntry : Model -> LedgerEntry -> List ( String, Html Msg )
viewKeyedLedgerEntry model entry =
    case viewLedgerEntry model entry of
        [] ->
            []

        parent :: details ->
            let
                xid =
                    String.fromInt entry.xid

                detailKeys =
                    if model.transactionXid == Just entry.xid && not model.transactionSimple then
                        List.map
                            (\line -> "txn:" ++ xid ++ ":line:" ++ String.fromInt line.key)
                            (nonBlankDraftLines model)
                            ++ [ "txn:" ++ xid ++ ":blank:" ++ String.fromInt model.nextDraftKey ]

                    else
                        []
            in
            ( "txn:" ++ xid ++ ":parent", parent )
                :: List.map2 Tuple.pair detailKeys details


viewLedgerEntry : Model -> LedgerEntry -> List (Html Msg)
viewLedgerEntry model entry =
    if model.transactionXid == Just entry.xid then
        viewSelectedLedgerEntry model entry

    else
        [ viewReadLedgerRow model entry ]


ledgerSyncLabel : LedgerSync -> String
ledgerSyncLabel sync =
    case sync of
        LedgerIdle ->
            "idle"

        LedgerSaving _ ->
            "saving"

        LedgerRefreshing _ ->
            "refreshing"


viewReadLedgerRow : Model -> LedgerEntry -> Html Msg
viewReadLedgerRow model entry =
    Html.tr
        [ ledgerRowClasses entry False
        , Attr.attribute "data-xid" (String.fromInt entry.xid)
        , Attr.attribute "aria-label" (presentationTextWith model "aria.transaction.edit" [ ( "date", entry.date ) ])
        , Attr.tabindex 0
        , Events.onClick (EditTransaction entry)
        , onRowActivate (EditTransaction entry)
        ]
        [ Html.td [ Attr.class "ledger-date" ] [ Html.text entry.date ]
        , Html.td [ Attr.class "ledger-description" ] [ Html.text (Maybe.withDefault "" entry.description) ]
        , Html.td [ Attr.class "ledger-transfer" ] [ Html.text (Maybe.withDefault (if entry.split then presentationText model "option.transaction.split" else "") entry.transfer) ]
        , Html.td [ Attr.class "number ledger-deposit" ] [ Html.text (positiveDecimal entry.amount) ]
        , Html.td [ Attr.class "number ledger-withdrawal" ] [ Html.text (negativeDecimal entry.amount) ]
        , Html.td [ Attr.class "number ledger-balance" ] [ Html.text entry.balance ]
        ]


viewSelectedLedgerEntry : Model -> LedgerEntry -> List (Html Msg)
viewSelectedLedgerEntry model entry =
    case primaryDraftLine model of
        Nothing ->
            [ viewReadLedgerRow model entry ]

        Just primary ->
            let
                detailRows =
                    if model.transactionSimple then
                        []

                    else
                        List.map (viewInlineSplitLine model entry.xid) (nonBlankDraftLines model)
                            ++ [ viewBlankSplitLine model entry.xid ]
            in
            viewInlineParentRow model entry primary
                :: detailRows


viewInlineParentRow : Model -> LedgerEntry -> DraftLine -> Html Msg
viewInlineParentRow model entry primary =
    Html.tr
        [ ledgerRowClasses entry True
        , Attr.attribute "data-xid" (String.fromInt entry.xid)
        ]
        [ Html.td [ Attr.class "ledger-date" ]
            [ registerInput model.navigationLocked TransactionDateField (presentationText model "field.transaction.date") "date" model.transactionDate UpdateTransactionDate ]
        , Html.td [ Attr.class "ledger-description" ]
            [ registerInput model.navigationLocked TransactionCommentField (presentationText model "field.transaction.description") "text" model.transactionComment UpdateTransactionComment ]
        , Html.td [ Attr.class "ledger-transfer" ] [ viewInlineTransfer model ]
        , Html.td [ Attr.class "ledger-deposit" ]
            [ registerMoneyInput model.navigationLocked False (DraftAmountField primary.key) primary.amount (presentationText model "field.transaction.deposit") (positiveInput primary.amount) Nothing
                (\value -> UpdateDraftAmount primary.key value)
            ]
        , Html.td [ Attr.class "ledger-withdrawal" ]
            [ registerMoneyInput model.navigationLocked False (DraftAmountField primary.key) primary.amount (presentationText model "field.transaction.withdrawal") (negativeInput primary.amount) Nothing
                (\value -> UpdateDraftAmount primary.key (negativeAmount value))
            ]
        , Html.td [ Attr.class "number ledger-balance" ] [ Html.text entry.balance ]
        ]


viewInlineTransfer : Model -> Html Msg
viewInlineTransfer model =
    if model.transactionSimple then
        let
            transfer =
                counterpartDraftLines model |> List.head |> Maybe.withDefault (emptyDraft 0)

            primaryAccount =
                primaryDraftLine model |> Maybe.map .account |> Maybe.withDefault ""

            transferAccounts =
                List.filter (\account -> account.id /= primaryAccount) model.accounts
        in
        transferAccountSelect model transfer transferAccounts

    else
        Html.span [ Attr.class "split-label" ] [ Html.text (presentationText model "option.transaction.split") ]


viewInlineSplitLine : Model -> Int -> DraftLine -> Html Msg
viewInlineSplitLine model xid line =
    Html.tr
        [ Attr.class "ledger-split-line ledger-edit-line"
        , Attr.attribute "data-xid" (String.fromInt xid)
        , Attr.attribute "data-account" line.account
        , Attr.attribute "data-draft" "line"
        ]
        [ Html.td [ Attr.class "ledger-date split-empty-date" ] []
        , Html.td [ Attr.class "ledger-description" ]
            [ registerInput model.navigationLocked (DraftMemoField line.key) (presentationText model "field.transaction.memo") "text" line.memo (UpdateDraftMemo line.key) ]
        , Html.td [ Attr.class "ledger-transfer" ]
            [ accountSelect model (DraftAccountField line.key) (presentationText model "column.account") model.accounts line.account (UpdateDraftAccount line.key) ]
        , Html.td [ Attr.class "ledger-deposit" ]
            [ registerMoneyInput model.navigationLocked False (DraftAmountField line.key) line.amount (presentationText model "field.transaction.deposit") (positiveInput line.amount) Nothing
                (\value -> UpdateDraftAmount line.key value)
            ]
        , Html.td [ Attr.class "ledger-withdrawal" ]
            [ registerMoneyInput model.navigationLocked False (DraftAmountField line.key) line.amount (presentationText model "field.transaction.withdrawal") (negativeInput line.amount) Nothing
                (\value -> UpdateDraftAmount line.key (negativeAmount value))
            ]
        , Html.td [ Attr.class "ledger-balance muted-cell" ] []
        ]


viewBlankSplitLine : Model -> Int -> Html Msg
viewBlankSplitLine model xid =
    let
        key =
            model.nextDraftKey

        suggestedAmount =
            Maybe.map .amount model.draftBalance

        suggestedDeposit =
            suggestedAmount |> Maybe.map positiveInput |> Maybe.andThen nonBlankMaybe

        suggestedWithdrawal =
            suggestedAmount |> Maybe.map negativeInput |> Maybe.andThen nonBlankMaybe

        rowAttributes =
            [ Attr.classList
                [ ( "ledger-split-line", True )
                , ( "ledger-edit-line", True )
                , ( "ledger-blank-split", True )
                , ( "ledger-balancing-split", model.draftBalance /= Nothing )
                ]
            , Attr.attribute "data-xid" (String.fromInt xid)
            , Attr.attribute "data-account" ""
            , Attr.attribute "data-draft" "blank"
            ]
                ++ (case model.draftBalance of
                        Just balance ->
                            [ Attr.attribute "data-suggested-asset" balance.asset ]

                        Nothing ->
                            []
                   )
    in
    Html.tr
        rowAttributes
        [ Html.td [ Attr.class "ledger-date split-empty-date" ] []
        , Html.td [ Attr.class "ledger-description" ]
            [ registerInput model.navigationLocked (DraftMemoField key) (presentationText model "aria.split.memo") "text" "" MaterializeDraftMemo ]
        , Html.td [ Attr.class "ledger-transfer" ]
            [ accountSelect model (DraftAccountField key) (presentationText model "aria.split.account") model.accounts "" MaterializeDraftAccount ]
        , Html.td [ Attr.class "ledger-deposit" ]
            [ registerMoneyInput model.navigationLocked False (DraftAmountField key) "" (presentationText model "aria.split.deposit") "" suggestedDeposit MaterializeDraftAmount ]
        , Html.td [ Attr.class "ledger-withdrawal" ]
            [ registerMoneyInput model.navigationLocked True (DraftAmountField key) "" (presentationText model "aria.split.withdrawal") "" suggestedWithdrawal (negativeAmount >> MaterializeDraftAmount) ]
        , Html.td [ Attr.class "ledger-balance muted-cell" ] []
        ]


viewAppendRows : Model -> List (Html Msg)
viewAppendRows model =
    case model.transactionXid of
        Just _ ->
            [ Html.tr
                [ Attr.class "append-row append-launcher"
                , Attr.tabindex 0
                , Events.onClick StartNewTransaction
                , onRowActivate StartNewTransaction
                ]
                [ Html.td [ Attr.colspan 6 ] [ Html.text (presentationText model "action.transaction.new") ] ]
            ]

        Nothing ->
            case primaryDraftLine model of
                Nothing ->
                    []

                Just primary ->
                    let
                        detailRows =
                            if model.transactionSimple then
                                []

                            else
                                List.map (viewInlineSplitLine model 0) (nonBlankDraftLines model)
                                    ++ [ viewBlankSplitLine model 0 ]
                    in
                    viewAppendParentRow model primary
                        :: detailRows


viewAppendParentRow : Model -> DraftLine -> Html Msg
viewAppendParentRow model primary =
    Html.tr [ Attr.class "append-row" ]
        [ Html.td [ Attr.class "ledger-date" ]
            [ registerInput model.navigationLocked TransactionDateField (presentationText model "aria.transaction.new-date") "date" model.transactionDate UpdateTransactionDate ]
        , Html.td [ Attr.class "ledger-description" ]
            [ registerInput model.navigationLocked TransactionCommentField (presentationText model "aria.transaction.new-description") "text" model.transactionComment UpdateTransactionComment ]
        , Html.td [ Attr.class "ledger-transfer" ] [ viewInlineTransfer model ]
        , Html.td [ Attr.class "ledger-deposit" ]
            [ registerMoneyInput model.navigationLocked False (DraftAmountField primary.key) primary.amount (presentationText model "aria.transaction.new-deposit") (positiveInput primary.amount) Nothing
                (\value -> UpdateDraftAmount primary.key value)
            ]
        , Html.td [ Attr.class "ledger-withdrawal" ]
            [ registerMoneyInput model.navigationLocked False (DraftAmountField primary.key) primary.amount (presentationText model "aria.transaction.new-withdrawal") (negativeInput primary.amount) Nothing
                (\value -> UpdateDraftAmount primary.key (negativeAmount value))
            ]
        , Html.td [ Attr.class "ledger-balance muted-cell" ] []
        ]


ledgerRowClasses : LedgerEntry -> Bool -> Html.Attribute Msg
ledgerRowClasses entry selected =
    Attr.classList
        [ ( "ledger-line", True )
        , ( "ledger-line-green", modBy 2 entry.xid == 0 )
        , ( "ledger-line-yellow", modBy 2 entry.xid /= 0 )
        , ( "ledger-row-selected", selected )
        ]


primaryDraftLine : Model -> Maybe DraftLine
primaryDraftLine model =
    model.draftLines
        |> List.filter (\line -> line.key == model.transactionPrimaryKey)
        |> List.head


counterpartDraftLines : Model -> List DraftLine
counterpartDraftLines model =
    List.filter (\line -> line.key /= model.transactionPrimaryKey) model.draftLines


transferAccountSelect : Model -> DraftLine -> List Account -> Html Msg
transferAccountSelect model transfer accounts =
    Html.select
        [ Attr.attribute "aria-label" (presentationText model "field.transaction.transfer")
        , Attr.value transfer.account
        , Attr.disabled model.navigationLocked
        , Events.onFocus (FocusRegisterField (DraftAccountField transfer.key) transfer.account)
        , Events.onInput
            (\value ->
                if value == splitTransactionValue then
                    UseSplitTransaction

                else
                    UpdateDraftAccount transfer.key value
            )
        , onRegisterKey False (DraftAccountField transfer.key)
        ]
        (emptyAccountOption model transfer.account
            ++ (Html.option [ Attr.value splitTransactionValue ] [ Html.text (presentationText model "option.transaction.split") ]
                    :: List.map (accountOption transfer.account) accounts
               )
        )


accountOption : String -> Account -> Html Msg
accountOption current account =
    Html.option
        [ Attr.value account.id, Attr.selected (account.id == current) ]
        [ Html.text account.id ]


accountSelect : Model -> RegisterField -> String -> List Account -> String -> (String -> Msg) -> Html Msg
accountSelect model field label accounts current toMsg =
    Html.select
        [ Attr.attribute "aria-label" label
        , Attr.value current
        , Attr.disabled model.navigationLocked
        , Events.onFocus (FocusRegisterField field current)
        , Events.onInput toMsg
        , onRegisterKey False field
        ]
        (emptyAccountOption model current ++ List.map (accountOption current) accounts)


emptyAccountOption : Model -> String -> List (Html Msg)
emptyAccountOption model current =
    if current == "" then
        [ Html.option [ Attr.attribute "value" "", Attr.selected True ] [ Html.text (presentationText model "option.account.select") ] ]

    else
        []


registerInput : Bool -> RegisterField -> String -> String -> String -> (String -> Msg) -> Html Msg
registerInput disabled field label inputType value toMsg =
    Html.input
        [ Attr.type_ inputType
        , Attr.class "ledger-edit-input"
        , Attr.attribute "aria-label" label
        , Attr.value value
        , Attr.disabled disabled
        , Events.onFocus (FocusRegisterField field value)
        , Events.onInput toMsg
        , onRegisterKey False field
        ]
        []


registerMoneyInput : Bool -> Bool -> RegisterField -> String -> String -> String -> Maybe String -> (String -> Msg) -> Html Msg
registerMoneyInput disabled commitOnBlankTab field rawValue label value suggestion toMsg =
    Html.input
        [ Attr.type_ "text"
        , Attr.classList
            [ ( "ledger-edit-input", True )
            , ( "number-input", True )
            , ( "balancing-amount-input", suggestion /= Nothing )
            ]
        , Attr.attribute "aria-label" label
        , Attr.attribute "inputmode" "decimal"
        , Attr.value value
        , Attr.placeholder (Maybe.withDefault "" suggestion)
        , Attr.disabled disabled
        , Events.onFocus (FocusRegisterField field rawValue)
        , Events.onInput toMsg
        , Events.onBlur RefreshDraftBalance
        , onRegisterKey commitOnBlankTab field
        ]
        []


boolString : Bool -> String
boolString value =
    if value then "true" else "false"


onRegisterKey : Bool -> RegisterField -> Html.Attribute Msg
onRegisterKey commitOnBlankTab field =
    Events.preventDefaultOn "keydown"
        (Decode.map2 Tuple.pair
            (Decode.field "key" Decode.string)
            (Decode.field "shiftKey" Decode.bool)
            |> Decode.andThen
                (\( key, shifted ) ->
                    if key == "Enter" then
                        Decode.succeed ( SubmitTransaction, True )

                    else if key == "Escape" then
                        Decode.succeed ( RevertRegisterField field, True )

                    else if commitOnBlankTab && key == "Tab" && not shifted then
                        Decode.succeed ( SubmitTransaction, True )

                    else
                        Decode.fail "ignore key"
                )
        )


onRowActivate : Msg -> Html.Attribute Msg
onRowActivate message =
    Events.preventDefaultOn "keydown"
        (Decode.field "key" Decode.string
            |> Decode.andThen
                (\key ->
                    if key == "Enter" || key == " " then
                        Decode.succeed ( message, True )

                    else
                        Decode.fail "ignore key"
                )
        )


type DecimalPolarity
    = DecimalNegative
    | DecimalZero
    | DecimalPositive
    | DecimalInvalid


decimalPolarity : String -> DecimalPolarity
decimalPolarity amount =
    let
        trimmed =
            String.trim amount

        ( negative, unsigned ) =
            case String.uncons trimmed of
                Just ( '-', rest ) ->
                    ( True, rest )

                Just ( '+', rest ) ->
                    ( False, rest )

                _ ->
                    ( False, trimmed )

        exponentParts =
            String.split "e" (String.toLower unsigned)

        classify mantissa =
            case decimalMantissaDigits mantissa of
                Nothing ->
                    DecimalInvalid

                Just digits ->
                    if String.any isNonZeroDigit digits then
                        if negative then
                            DecimalNegative

                        else
                            DecimalPositive

                    else
                        DecimalZero
    in
    case exponentParts of
        [ mantissa ] ->
            classify mantissa

        [ mantissa, exponent ] ->
            if decimalExponentIsValid exponent then
                classify mantissa

            else
                DecimalInvalid

        _ ->
            DecimalInvalid


decimalMantissaDigits : String -> Maybe String
decimalMantissaDigits mantissa =
    case String.split "." mantissa of
        [ whole ] ->
            validDecimalDigits whole

        [ whole, fraction ] ->
            if String.all isDecimalDigit whole && String.all isDecimalDigit fraction then
                validDecimalDigits (whole ++ fraction)

            else
                Nothing

        _ ->
            Nothing


validDecimalDigits : String -> Maybe String
validDecimalDigits digits =
    if digits /= "" && String.all isDecimalDigit digits then
        Just digits

    else
        Nothing


decimalExponentIsValid : String -> Bool
decimalExponentIsValid exponent =
    let
        digits =
            case String.uncons exponent of
                Just ( '+', rest ) ->
                    rest

                Just ( '-', rest ) ->
                    rest

                _ ->
                    exponent
    in
    digits /= "" && String.all isDecimalDigit digits


isDecimalDigit : Char -> Bool
isDecimalDigit digit =
    digit >= '0' && digit <= '9'


isNonZeroDigit : Char -> Bool
isNonZeroDigit digit =
    digit >= '1' && digit <= '9'


decimalHasMagnitude : String -> Bool
decimalHasMagnitude amount =
    case decimalPolarity amount of
        DecimalPositive ->
            True

        DecimalNegative ->
            True

        _ ->
            False


positiveDecimal : String -> String
positiveDecimal amount =
    if decimalPolarity amount == DecimalPositive then
        amount

    else
        ""


negativeDecimal : String -> String
negativeDecimal amount =
    if decimalPolarity amount == DecimalNegative then
        String.dropLeft 1 (String.trim amount)

    else
        ""


positiveInput : String -> String
positiveInput amount =
    case decimalPolarity amount of
        DecimalPositive ->
            amount

        DecimalInvalid ->
            if String.startsWith "-" (String.trim amount) then "" else amount

        _ ->
            ""


negativeInput : String -> String
negativeInput amount =
    case decimalPolarity amount of
        DecimalNegative ->
            String.dropLeft 1 (String.trim amount)

        DecimalInvalid ->
            if String.startsWith "-" (String.trim amount) then
                String.dropLeft 1 (String.trim amount)

            else
                ""

        _ ->
            ""


negativeAmount : String -> String
negativeAmount amount =
    if String.trim amount == "" then "" else "-" ++ amount


viewReconciliation : Model -> Html Msg
viewReconciliation model =
    let
        currentAccount =
            Maybe.withDefault "" model.reconciliationAccount

        total =
            List.length model.reconciliationRows

        unreconciled =
            model.reconciliationRows
                |> List.filter (\row -> not row.reconciled)
                |> List.length
    in
    Html.section [ Attr.class "panel reconciliation-panel" ]
        [ sectionHeader (presentationText model "page.reconciliation.title")
            (Html.div [ Attr.class "reconciliation-context" ]
                [ selectControl model.navigationLocked (presentationText model "field.account.filter") currentAccount SelectReconciliationAccount
                    (( "", presentationText model "option.account.all" )
                        :: List.map (\account -> ( account.id, account.id )) model.accounts
                    )
                ]
            )
        , viewValidationMessages model.pageValidation
        , Html.p [ Attr.class "reconciliation-summary" ]
            [ Html.text
                (presentationTextWith model "page.reconciliation.summary"
                    [ ( "unreconciled", String.fromInt unreconciled )
                    , ( "total", String.fromInt total )
                    ]
                )
            ]
        , if List.isEmpty model.reconciliationRows then
            Html.p [ Attr.class "muted-cell" ] [ Html.text (presentationText model "page.reconciliation.empty") ]

          else
            Html.table [ Attr.class "data-table reconciliation-table" ]
                [ Html.thead []
                    [ Html.tr []
                        [ Html.th [] [ Html.text (presentationText model "field.transaction.date") ]
                        , Html.th [] [ Html.text (presentationText model "field.transaction.description") ]
                        , Html.th [] [ Html.text (presentationText model "column.account") ]
                        , Html.th [] [ Html.text (presentationText model "field.asset") ]
                        , Html.th [ Attr.class "number" ] [ Html.text (presentationText model "field.transaction.deposit") ]
                        , Html.th [ Attr.class "number" ] [ Html.text (presentationText model "field.transaction.withdrawal") ]
                        , Html.th [ Attr.class "reconciliation-status" ] [ Html.text (presentationText model "field.reconciliation.reconciled") ]
                        ]
                    ]
                , Html.tbody [] (List.map (viewReconciliationRow model) model.reconciliationRows)
                ]
        ]


viewReconciliationRow : Model -> ReconciliationEntry -> Html Msg
viewReconciliationRow model row =
    Html.tr
        [ Attr.classList
            [ ( "reconciliation-row", True )
            , ( "reconciliation-row-open", not row.reconciled )
            ]
        , Attr.attribute "data-xid" (String.fromInt row.xid)
        , Attr.attribute "data-account" row.account
        ]
        [ Html.td [] [ Html.text row.date ]
        , Html.td [] [ Html.text (Maybe.withDefault "" row.description) ]
        , Html.td [] [ Html.text row.account ]
        , Html.td [] [ Html.text row.asset ]
        , Html.td [ Attr.class "number" ] [ Html.text (positiveDecimal row.amount) ]
        , Html.td [ Attr.class "number" ] [ Html.text (negativeDecimal row.amount) ]
        , Html.td [ Attr.class "reconciliation-status" ]
            [ Html.input
                [ Attr.type_ "checkbox"
                , Attr.checked row.reconciled
                , Attr.disabled model.navigationLocked
                , Attr.attribute "aria-label" (presentationTextWith model "aria.reconciled-posting" [ ( "account", row.account ), ( "date", row.date ) ])
                , Events.onCheck (SetPostingReconciled row.xid row.account)
                ]
                []
            ]
        ]


viewReports : Model -> Html Msg
viewReports model =
    Html.section [ Attr.class "panel reports-library" ]
        [ sectionHeader (presentationText model "page.reports.title") (Html.text "")
        , viewValidationMessages model.pageValidation
        , Html.p [ Attr.class "reports-introduction" ]
            [ Html.text (presentationText model "page.reports.intro") ]
        , Html.div [ Attr.class "report-groups" ]
            (List.map
                (viewReportGroup model)
                (reportGroups model.reportOptions)
            )
        ]


reportGroups : List ReportOption -> List String
reportGroups reports =
    List.foldl
        (\report groups ->
            if List.member report.group groups then
                groups

            else
                groups ++ [ report.group ]
        )
        []
        reports


viewReportGroup : Model -> String -> Html Msg
viewReportGroup model group =
    Html.section [ Attr.class "report-group" ]
        [ Html.h3 [ Attr.class "report-group-heading" ] [ Html.text group ]
        , Html.div [ Attr.class "report-grid" ]
            (model.reportOptions
                |> List.filter (\report -> report.group == group)
                |> List.map (viewReportChoice model)
            )
        ]


viewReportChoice : Model -> ReportOption -> Html Msg
viewReportChoice model report =
    let
        descriptionId =
            "report-description-" ++ report.id
    in
    Html.a
        [ Attr.class "report-card"
        , Attr.href
            (routeHref
                { page = ReportPage
                , book = model.selectedBook
                , account = Nothing
                , report = Just report.id
                }
            )
        , Attr.attribute "aria-describedby" descriptionId
        ]
        [ Html.h4
            [ Attr.class "report-choice"
            , Attr.attribute "aria-describedby" descriptionId
            ]
            [ Html.text report.name ]
        , Html.p [ Attr.id descriptionId ] [ Html.text report.description ]
        ]


viewJournal : Model -> Html Msg
viewJournal model =
    Html.section [ Attr.class "panel journal-panel" ]
        [ sectionHeader (presentationText model "page.journal.title") (Html.text "")
        , viewValidationMessages model.pageValidation
        , Html.table [ Attr.class "data-table general-journal-table" ]
            [ Html.thead [] [ Html.tr [] [ Html.th [ Attr.class "journal-date" ] [ Html.text (presentationText model "field.transaction.date") ], Html.th [ Attr.class "journal-description" ] [ Html.text (presentationText model "field.transaction.description") ], Html.th [ Attr.class "journal-reconciled" ] [ Html.text (presentationText model "field.transaction.reconciled-short") ], Html.th [ Attr.class "journal-account" ] [ Html.text (presentationText model "column.account") ], Html.th [ Attr.class "journal-memo" ] [ Html.text (presentationText model "field.transaction.memo") ], Html.th [ Attr.class "number journal-debit" ] [ Html.text (presentationText model "field.transaction.debit") ], Html.th [ Attr.class "number journal-credit" ] [ Html.text (presentationText model "field.transaction.credit") ] ] ]
            , Html.tbody [] (List.map (viewJournalRow model) model.journal)
            ]
        ]


viewJournalRow : Model -> JournalRow -> Html Msg
viewJournalRow model row =
    Html.tr
        [ Attr.classList
            [ ( "journal-group-even", modBy 2 row.xid == 0 )
            , ( "journal-group-odd", modBy 2 row.xid /= 0 )
            , ( "journal-first-line", row.lineOrder == 1 )
            , ( "journal-unreconciled", not row.reconciled )
            ]
        ]
        [ Html.td [ Attr.class "journal-date" ] [ Html.text (if row.lineOrder == 1 then row.date else "") ]
        , Html.td [ Attr.class "journal-description" ] [ Html.text (if row.lineOrder == 1 then Maybe.withDefault "" row.description else "") ]
        , Html.td
            [ Attr.class "journal-reconciled"
            , Attr.title (presentationText model (if row.reconciled then "state.reconciled-posting" else "state.unreconciled-posting"))
            ]
            [ Html.text (if row.reconciled then presentationText model "field.transaction.reconciled-short" else "") ]
        , Html.td [ Attr.classList [ ( "journal-account", True ), ( "journal-credit-account", row.credit /= Nothing ) ] ] [ Html.text row.account ]
        , Html.td [ Attr.class "journal-memo" ] [ Html.text (Maybe.withDefault "" row.memo) ]
        , Html.td [ Attr.class "number journal-debit" ] [ Html.text (Maybe.withDefault "" row.debit) ]
        , Html.td [ Attr.class "number journal-credit" ] [ Html.text (Maybe.withDefault "" row.credit) ]
        ]


viewDatabaseReport : Model -> Html Msg
viewDatabaseReport model =
    case model.reportDefinition of
        Nothing ->
            Html.section [ Attr.class "panel narrow-page" ]
                [ sectionHeader (presentationText model "page.report.unavailable") (Html.text "")
                , viewValidationMessages model.pageValidation
                ]

        Just definition ->
            Html.section [ Attr.class "panel database-report" ]
                [ sectionHeader definition.title (Html.text "")
                , case definition.parameterKind of
                    "period" ->
                        viewPeriodToolbar model

                    "as_of" ->
                        viewAsOfToolbar model

                    _ ->
                        Html.text ""
                , viewValidationMessages model.pageValidation
                , Html.p [ Attr.class "reports-introduction" ] [ Html.text definition.description ]
                , Html.div [ Attr.class "report-chart-list" ]
                    (List.map
                        (\chart ->
                            viewBarChart model chart
                                (List.filter (\point -> point.chartId == chart.id) model.barChartPoints)
                        )
                        model.barChartDefinitions
                    )
                , Html.table [ Attr.class "data-table report-table database-report-table" ]
                    [ Html.thead []
                        [ Html.tr []
                            (List.map viewGenericReportHeader model.reportColumns)
                        ]
                    , Html.tbody []
                        (List.map (viewGenericReportRow model.reportColumns) model.genericReportRows)
                    ]
                ]


viewGenericReportHeader : ReportColumn -> Html Msg
viewGenericReportHeader column =
    Html.th
        [ Attr.classList [ ( "number", column.alignment == "right" ) ] ]
        [ Html.text column.label ]


viewGenericReportRow : List ReportColumn -> GenericReportRow -> Html Msg
viewGenericReportRow columns row =
    Html.tr
        ([ reportRowClasses row.rowKind
         , Attr.attribute "data-depth" (String.fromInt row.depth)
         , Attr.attribute "data-row-kind" row.rowKind
         ]
            ++ (case row.accountId of
                    Just accountId ->
                        [ Attr.attribute "data-account-id" accountId ]

                    Nothing ->
                        []
               )
        )
        (List.map (viewGenericReportCell row) columns)


viewGenericReportCell : GenericReportRow -> ReportColumn -> Html Msg
viewGenericReportCell row column =
    let
        cell =
            row.cells
                |> List.filter (\candidate -> candidate.columnId == column.id)
                |> List.head

        rendered =
            case cell of
                Nothing ->
                    ""

                Just value ->
                    case value.text of
                        Just textValue ->
                            textValue

                        Nothing ->
                            case value.exact of
                                Just exactValue ->
                                    formatReportExact column.valueFormat exactValue value.suffix

                                Nothing ->
                                    ""

        indentation =
            if column.treeColumn then
                [ Attr.style "padding-left" (String.fromFloat (toFloat row.depth * 2.5 + 0.65) ++ "rem") ]

            else
                []
    in
    Html.td
        ([ Attr.classList
            [ ( "number", column.alignment == "right" )
            , ( "report-tree-account", column.treeColumn )
             , ( "report-account", column.treeColumn )
            ]
         , Attr.attribute "data-value-format" column.valueFormat
         ]
            ++ indentation
        )
        [ Html.span
            [ Attr.classList [ ( "report-account-name", column.treeColumn ) ] ]
            [ Html.text rendered ]
        ]


viewBarChart : Model -> BarChartDefinition -> List BarChartPoint -> Html Msg
viewBarChart model definition points =
    let
        values =
            List.filterMap .value points

        upper =
            max 0 (Maybe.withDefault 0 (List.maximum values))

        lower =
            min 0 (Maybe.withDefault 0 (List.minimum values))

        valueRange =
            max 1 (upper - lower)

        baseline =
            (0 - lower) / valueRange * 100

        latestPoint =
            List.reverse points |> List.head

        latestValue =
            latestPoint
                |> Maybe.andThen (formattedBarPointValue definition)
                |> Maybe.withDefault ""

        summary =
            if latestValue == "" then
                presentationTextWith model "chart.summary.unavailable"
                    [ ( "label", definition.valueLabel ) ]

            else
                presentationTextWith model "chart.summary.value"
                    [ ( "label", definition.valueLabel ), ( "value", latestValue ) ]
    in
    Html.figure
        [ Attr.class "report-bar-chart"
        , Attr.attribute "data-value-format" definition.valueFormat
        ]
        [ Html.div [ Attr.class "report-bar-chart-heading" ]
            [ Html.h3 [] [ Html.text definition.title ]
            , Html.span [] [ Html.text summary ]
            ]
        , Html.div
            [ Attr.class "report-bar-chart-plot"
            , Attr.attribute "role" "img"
            , Attr.attribute "aria-label"
                (presentationTextWith model "aria.chart.bar" [ ( "summary", summary ) ])
            ]
            [ Html.div
                [ Attr.class "report-bar-zero-line"
                , Attr.style "bottom" (percentage baseline)
                , Attr.attribute "aria-hidden" "true"
                ]
                []
            , Html.div [ Attr.class "report-bars" ]
                (List.map (viewBarChartPoint model definition lower valueRange baseline) points)
            ]
        , Html.ul [ Attr.class "visually-hidden report-chart-data" ]
            (List.map
                (\point -> Html.li [] [ Html.text (barPointLabel model definition point) ])
                points
            )
        ]


viewBarChartPoint : Model -> BarChartDefinition -> Float -> Float -> Float -> BarChartPoint -> Html Msg
viewBarChartPoint model definition lower valueRange baseline point =
    let
        value =
            Maybe.withDefault 0 point.value

        height =
            abs value / valueRange * 100

        bottom =
            if value >= 0 then
                baseline

            else
                (value - lower) / valueRange * 100

        accessibleLabel =
            barPointLabel model definition point
    in
    Html.div [ Attr.class "report-bar-column" ]
        [ Html.div [ Attr.class "report-bar-area" ]
            [ Html.div
                [ Attr.classList
                    [ ( "report-bar", True )
                    , ( "report-bar-negative", value < 0 )
                    , ( "report-bar-missing", point.value == Nothing )
                    ]
                , Attr.style "height" (percentage height)
                , Attr.style "bottom" (percentage bottom)
                , Attr.title accessibleLabel
                , Attr.attribute "aria-label" accessibleLabel
                ]
                []
            ]
        , Html.span [ Attr.class "report-bar-label" ] [ Html.text (shortPeriodLabel model point.label) ]
        ]


formatReportExact : String -> String -> Maybe String -> String
formatReportExact valueFormat value suffix =
    value
        ++ (case ( valueFormat, suffix ) of
                ( "percent", Nothing ) ->
                    " %"

                ( _, Just unit ) ->
                    " " ++ unit

                _ ->
                    ""
           )


formattedBarPointValue : BarChartDefinition -> BarChartPoint -> Maybe String
formattedBarPointValue definition point =
    Maybe.map
        (\exactValue -> formatReportExact definition.valueFormat exactValue point.suffix)
        point.exact


barPointLabel : Model -> BarChartDefinition -> BarChartPoint -> String
barPointLabel model definition point =
    presentationTextWith model "chart.point.label"
        [ ( "period", point.label )
        , ( "label", definition.valueLabel )
        , ( "value"
          , Maybe.withDefault
                (presentationText model "chart.value.unavailable")
                (formattedBarPointValue definition point)
          )
        ]


percentage : Float -> String
percentage value =
    String.fromFloat (clamp 0 100 value) ++ "%"


shortPeriodLabel : Model -> String -> String
shortPeriodLabel model date =
    let
        month =
            presentationText model ("month.short." ++ String.slice 5 7 date)
    in
    month ++ " " ++ String.slice 2 4 date


viewValidationMessages : List String -> Html Msg
viewValidationMessages messages =
    if List.isEmpty messages then
        Html.text ""

    else
        Html.div
            [ Attr.class "validation-message"
            , Attr.attribute "role" "alert"
            , Attr.attribute "aria-live" "assertive"
            , Attr.attribute "aria-atomic" "true"
            ]
            (List.map (\message -> Html.p [] [ Html.text message ]) messages)


reportRowClasses : String -> Html.Attribute Msg
reportRowClasses rowKind =
    Attr.classList
        [ ( "report-row", True )
        , ( "report-account-row", rowKind == "account" )
        , ( "report-group-row", rowKind == "group" )
        , ( "report-computed-row", rowKind == "computed" )
        , ( "report-section-total", rowKind == "section_total" || rowKind == "total" )
        , ( "report-grand-total", rowKind == "grand_total" )
        , ( "report-difference-row", rowKind == "difference" )
        , ( "report-total", rowKind /= "account" )
        ]


viewAsOfToolbar : Model -> Html Msg
viewAsOfToolbar model =
    Html.div [ Attr.class "report-toolbar" ]
        [ inputField (presentationText model "field.report.as-of") "date" model.reportDate UpdateReportDate
        , Html.button [ Attr.type_ "button", Events.onClick RefreshReport ] [ Html.text (presentationText model "action.report.refresh") ]
        ]


viewPeriodToolbar : Model -> Html Msg
viewPeriodToolbar model =
    Html.div [ Attr.class "report-toolbar period-report-toolbar" ]
        [ inputField (presentationText model "field.report.from") "date" model.reportFrom UpdateReportFrom
        , inputField (presentationText model "field.report.to") "date" model.reportTo UpdateReportTo
        , Html.button [ Attr.type_ "button", Events.onClick RefreshReport ] [ Html.text (presentationText model "action.report.refresh") ]
        ]


viewAddBook : Model -> Html Msg
viewAddBook model =
    Html.section [ Attr.class "panel narrow-page form-page" ]
        [ sectionHeader (presentationText model "page.book.add.title") (Html.text "")
        , Html.form [ Attr.class "form", Events.onSubmit SubmitBook ]
            [ inputField (presentationText model "field.book.id") "text" model.bookIdInput UpdateBookId
            , inputField (presentationText model "field.book.name") "text" model.bookNameInput UpdateBookName
            , choicePairsField (presentationText model "field.book.owner-entity") model.bookEntityTypeInput UpdateBookEntityType
                (namedOptionPairs model.bookEntityTypeOptions)
                False
            , choiceField (presentationText model "field.book.reporting-asset") model.bookAssetInput UpdateBookAsset model.assets
            , Html.button [ Attr.type_ "submit" ] [ Html.text (presentationText model "action.book.create") ]
            ]
        ]


viewAddAccount : Model -> Html Msg
viewAddAccount model =
    let
        parentChoices =
            List.map
                (\option -> ( option.id, option.path ))
                model.parentAccountOptions

        kindChoices =
            availableAccountKinds model
                |> List.map (\option -> ( option.id, option.label ))
    in
    Html.section [ Attr.class "panel narrow-page form-page" ]
        [ sectionHeader (presentationText model "page.account.add.title") (Html.text "")
        , viewValidationMessages model.pageValidation
        , Html.form [ Attr.class "form", Events.onSubmit SubmitAccount ]
            [ inputField (presentationText model "field.account.name") "text" model.accountIdInput UpdateAccountId
            , choicePairsField (presentationText model "field.account.parent") model.accountParentInput UpdateAccountParent parentChoices False
            , choicePairsField (presentationText model "field.account.class") model.accountTypeInput UpdateAccountType
                (List.map (\accountType -> ( accountType, accountType )) model.accountTypes)
                (model.accountParentInput /= "")
            , choiceField (presentationText model "field.account.commodity") model.accountAssetInput UpdateAccountAsset model.assets
            , choicePairsField (presentationText model "field.account.kind") model.accountKindInput UpdateAccountKind kindChoices False
            , Html.label [ Attr.class "checkbox-field" ]
                [ Html.input
                    [ Attr.type_ "checkbox"
                    , Attr.checked model.accountPlaceholderInput
                    , Attr.disabled (model.accountKindInput == "group")
                    , Events.onCheck UpdateAccountPlaceholder
                    ]
                    []
                , Html.span [] [ Html.text (presentationText model "field.account.placeholder") ]
                ]
            , inputField (presentationText model "field.account.pretax") "text" model.accountPretaxInput UpdateAccountPretax
            , inputField (presentationText model "field.account.opening-balance") "text" model.openingBalanceInput UpdateOpeningBalance
            , inputField (presentationText model "field.account.opening-date") "date" model.openingDateInput UpdateOpeningDate
            , Html.button [ Attr.type_ "submit" ] [ Html.text (presentationText model "action.account.create") ]
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


textareaField : String -> String -> (String -> Msg) -> Html Msg
textareaField label value toMsg =
    Html.label [ Attr.class "field textarea-field" ]
        [ Html.span [] [ Html.text label ]
        , Html.textarea [ Attr.value value, Attr.rows 3, Events.onInput toMsg ] []
        ]


readOnlyInputField : String -> String -> String -> Html Msg
readOnlyInputField label value note =
    Html.label [ Attr.class "field read-only-field" ]
        [ Html.span [] [ Html.text label ]
        , Html.input
            [ Attr.type_ "text"
            , Attr.value value
            , Attr.readonly True
            , Attr.title note
            ]
            []
        , Html.span [ Attr.class "field-note" ] [ Html.text note ]
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


choicePairsField : String -> String -> (String -> Msg) -> List ( String, String ) -> Bool -> Html Msg
choicePairsField label current toMsg choices disabled =
    Html.label [ Attr.class "field" ]
        [ Html.span [] [ Html.text label ]
        , Html.select [ Attr.value current, Attr.disabled disabled, Events.onInput toMsg ]
            (List.map
                (\( value, text ) ->
                    Html.option [ Attr.value value, Attr.selected (value == current) ] [ Html.text text ]
                )
                choices
            )
        ]


addAccountValue : String
addAccountValue =
    "__add_account__"


splitTransactionValue : String
splitTransactionValue =
    "__split_transaction__"


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
                    "admin_context" -> Decode.map AdminContextComponent (Decode.at [ "payload", "can_administer_global" ] Decode.bool)
                    "global_user" -> Decode.map GlobalUserComponent (Decode.field "payload" globalUserDecoder)
                    "book_identity" -> Decode.map BookIdentityComponent (Decode.field "payload" bookIdentityDecoder)
                    "book_access" -> Decode.map BookAccessComponent (Decode.field "payload" bookAccessDecoder)
                    "book_access_level_option" -> Decode.map BookAccessLevelOptionComponent (Decode.field "payload" namedOptionDecoder)
                    "book_entity_type_option" -> Decode.map BookEntityTypeOptionComponent (Decode.field "payload" namedOptionDecoder)
                    "reporting_currency" -> Decode.map ReportingCurrencyComponent (Decode.field "payload" reportingCurrencyDecoder)
                    "book_asset_option" -> Decode.map AssetComponent (Decode.at [ "payload", "id" ] Decode.string)
                    "company_profile" -> Decode.map CompanyProfileComponent (Decode.field "payload" companyProfileDecoder)
                    "legal_form_option" -> Decode.map LegalFormOptionComponent (Decode.field "payload" namedOptionDecoder)
                    "accounting_framework_option" -> Decode.map AccountingFrameworkOptionComponent (Decode.field "payload" namedOptionDecoder)
                    "vat_scheme_option" -> Decode.map VatSchemeOptionComponent (Decode.field "payload" namedOptionDecoder)
                    "period_status_option" -> Decode.map PeriodStatusOptionComponent (Decode.field "payload" namedOptionDecoder)
                    "accounting_period" -> Decode.map AccountingPeriodComponent (Decode.field "payload" accountingPeriodDecoder)
                    "vat_control_account_option" -> Decode.map VatControlAccountOptionComponent (Decode.field "payload" vatControlAccountOptionDecoder)
                    "configuration_check" -> Decode.map ConfigurationCheckComponent (Decode.field "payload" configurationCheckDecoder)
                    "panama_business_profile" -> Decode.map PanamaBusinessProfileComponent (Decode.field "payload" panamaBusinessProfileDecoder)
                    "panama_legal_form_option" -> Decode.map PanamaLegalFormOptionComponent (Decode.field "payload" namedOptionDecoder)
                    "panama_municipality_option" -> Decode.map PanamaMunicipalityOptionComponent (Decode.field "payload" namedOptionDecoder)
                    "panama_period_status_option" -> Decode.map PanamaPeriodStatusOptionComponent (Decode.field "payload" namedOptionDecoder)
                    "panama_fiscal_period" -> Decode.map PanamaFiscalPeriodComponent (Decode.field "payload" panamaFiscalPeriodDecoder)
                    "taiwan_business_profile" -> Decode.map TaiwanBusinessProfileComponent (Decode.field "payload" taiwanBusinessProfileDecoder)
                    "taiwan_legal_form_option" -> Decode.map TaiwanLegalFormOptionComponent (Decode.field "payload" namedOptionDecoder)
                    "taiwan_tax_frequency_option" -> Decode.map TaiwanTaxFrequencyOptionComponent (Decode.field "payload" namedOptionDecoder)
                    "taiwan_period_status_option" -> Decode.map TaiwanPeriodStatusOptionComponent (Decode.field "payload" namedOptionDecoder)
                    "taiwan_fiscal_period" -> Decode.map TaiwanFiscalPeriodComponent (Decode.field "payload" taiwanFiscalPeriodDecoder)
                    "account_option" -> Decode.map AccountComponent (Decode.field "payload" accountDecoder)
                    "account_row" -> Decode.map AccountSummaryComponent (Decode.field "payload" accountSummaryDecoder)
                    "parent_account_option" -> Decode.map ParentAccountOptionComponent (Decode.field "payload" parentAccountOptionDecoder)
                    "account_kind_option" -> Decode.map AccountKindOptionComponent (Decode.field "payload" accountKindOptionDecoder)
                    "report_option" -> Decode.map ReportOptionComponent (Decode.field "payload" reportOptionDecoder)
                    "report_definition" -> Decode.map ReportDefinitionComponent (Decode.field "payload" reportDefinitionDecoder)
                    "report_column" -> Decode.map ReportColumnComponent (Decode.field "payload" reportColumnDecoder)
                    "generic_report_row" -> Decode.map GenericReportRowComponent (Decode.field "payload" genericReportRowDecoder)
                    "bar_chart_definition" -> Decode.map BarChartDefinitionComponent (Decode.field "payload" barChartDefinitionDecoder)
                    "bar_chart_point" -> Decode.map BarChartPointComponent (Decode.field "payload" barChartPointDecoder)
                    "ledger_row" -> Decode.map LedgerComponent (Decode.field "payload" ledgerDecoder)
                    "journal_row" -> Decode.map JournalComponent (Decode.field "payload" journalDecoder)
                    "reconciliation_row" -> Decode.map ReconciliationComponent (Decode.field "payload" reconciliationEntryDecoder)
                    "asset_option" -> Decode.map AssetComponent (Decode.at [ "payload", "id" ] Decode.string)
                    "account_type_option" -> Decode.map AccountTypeComponent (Decode.at [ "payload", "id" ] Decode.string)
                    "page_context" -> Decode.map PageContextComponent (Decode.field "payload" pageContextDecoder)
                    "presentation" ->
                        Decode.map2 PresentationComponent
                            (Decode.at [ "payload", "key" ] Decode.string)
                            (Decode.at [ "payload", "text" ] Decode.string)
                    "language_option" ->
                        Decode.map LanguageOptionComponent (Decode.field "payload" languageOptionDecoder)
                    "book_access_context" -> Decode.succeed OtherComponent
                    "book_access_result" -> Decode.succeed OtherComponent
                    "global_user_result" -> Decode.succeed OtherComponent
                    _ -> Decode.fail ("Unknown page component: " ++ component)
            )


languageOptionDecoder : Decoder LanguageOption
languageOptionDecoder =
    Decode.map3 LanguageOption
        (Decode.field "locale" Decode.string)
        (Decode.field "flag" Decode.string)
        (Decode.field "label" Decode.string)


bookDecoder : Decoder Book
bookDecoder =
    Decode.map5 Book
        (Decode.field "id" Decode.string)
        (Decode.field "name" Decode.string)
        (Decode.field "reporting_asset" Decode.string)
        (optionalField "access_level" Decode.string "")
        (optionalField "selected" Decode.bool False)


bookAccessDecoder : Decoder BookAccess
bookAccessDecoder =
    Decode.succeed BookAccess
        |> andMap (Decode.field "principal_id" Decode.string)
        |> andMap (Decode.field "database_role" Decode.string)
        |> andMap (Decode.field "display_name" Decode.string)
        |> andMap (maybeField "github_login" Decode.string)
        |> andMap (Decode.field "access_level" Decode.string)
        |> andMap (Decode.field "status" Decode.string)
        |> andMap (optionalField "current_user" Decode.bool False)


globalUserDecoder : Decoder GlobalUser
globalUserDecoder =
    Decode.succeed GlobalUser
        |> andMap (Decode.field "principal_id" Decode.string)
        |> andMap (Decode.field "database_role" Decode.string)
        |> andMap (Decode.field "display_name" Decode.string)
        |> andMap (maybeField "github_login" Decode.string)
        |> andMap (Decode.field "status" Decode.string)
        |> andMap (Decode.field "book_count" Decode.int)
        |> andMap (Decode.field "global_admin" Decode.bool)
        |> andMap (Decode.field "current_user" Decode.bool)
        |> andMap (Decode.field "enabled" Decode.bool)
        |> andMap (Decode.field "can_change_enabled" Decode.bool)
        |> andMap (Decode.field "action_key" Decode.string)
        |> andMap (Decode.field "action_label" Decode.string)


bookIdentityDecoder : Decoder BookIdentity
bookIdentityDecoder =
    Decode.succeed BookIdentity
        |> andMap (Decode.field "id" Decode.string)
        |> andMap (Decode.field "name" Decode.string)
        |> andMap (Decode.field "reporting_asset" Decode.string)
        |> andMap (Decode.field "entity_type" Decode.string)
        |> andMap (Decode.field "entity_type_label" Decode.string)
        |> andMap (maybeField "archived_at" Decode.string)


reportingCurrencyDecoder : Decoder ReportingCurrency
reportingCurrencyDecoder =
    Decode.map3 ReportingCurrency
        (Decode.field "effective_from" Decode.string)
        (Decode.field "asset" Decode.string)
        (optionalField "current" Decode.bool False)


companyProfileDecoder : Decoder CompanyProfile
companyProfileDecoder =
    Decode.succeed CompanyProfile
        |> andMap (optionalField "enabled" Decode.bool False)
        |> andMap (Decode.field "legal_name" Decode.string)
        |> andMap (maybeField "company_number" Decode.string)
        |> andMap (Decode.field "legal_form" Decode.string)
        |> andMap (Decode.field "accounting_framework" Decode.string)
        |> andMap (maybeField "utr" Decode.string)
        |> andMap (maybeField "vat_registration_number" Decode.string)
        |> andMap (Decode.field "vat_scheme" Decode.string)
        |> andMap (maybeField "registered_office" Decode.string)
        |> andMap (maybeField "incorporated_on" Decode.string)
        |> andMap (maybeField "notes" Decode.string)


panamaBusinessProfileDecoder : Decoder PanamaBusinessProfile
panamaBusinessProfileDecoder =
    Decode.succeed PanamaBusinessProfile
        |> andMap (optionalField "enabled" Decode.bool False)
        |> andMap (Decode.field "legal_name" Decode.string)
        |> andMap (optionalField "ruc" Decode.string "")
        |> andMap (maybeField "verification_digit" Decode.string)
        |> andMap (Decode.field "legal_form" Decode.string)
        |> andMap (Decode.field "municipality" Decode.string)
        |> andMap (maybeField "incorporated_on" Decode.string)
        |> andMap (maybeField "resident_agent" Decode.string)
        |> andMap (maybeField "registered_address" Decode.string)
        |> andMap (maybeField "operations_notice_number" Decode.string)
        |> andMap (optionalField "itbms_registered" Decode.bool False)
        |> andMap (optionalField "conducts_lodging_activity" Decode.bool False)
        |> andMap (optionalField "residential_property_enabled" Decode.bool False)
        |> andMap (optionalField "property_count" Decode.int 0)
        |> andMap (maybeField "notes" Decode.string)


panamaFiscalPeriodDecoder : Decoder PanamaFiscalPeriod
panamaFiscalPeriodDecoder =
    Decode.succeed PanamaFiscalPeriod
        |> andMap (Decode.field "id" Decode.string)
        |> andMap (Decode.field "period_start" Decode.string)
        |> andMap (Decode.field "period_end" Decode.string)
        |> andMap (Decode.field "status" Decode.string)
        |> andMap (maybeField "income_tax_return_due_on" Decode.string)
        |> andMap (maybeField "municipal_return_due_on" Decode.string)
        |> andMap (maybeField "notes" Decode.string)


taiwanBusinessProfileDecoder : Decoder TaiwanBusinessProfile
taiwanBusinessProfileDecoder =
    Decode.succeed TaiwanBusinessProfile
        |> andMap (optionalField "enabled" Decode.bool False)
        |> andMap (Decode.field "legal_name" Decode.string)
        |> andMap (optionalField "unified_business_number" Decode.string "")
        |> andMap (Decode.field "legal_form" Decode.string)
        |> andMap (Decode.field "business_tax_frequency" Decode.string)
        |> andMap (optionalField "uses_uniform_invoices" Decode.bool True)
        |> andMap (maybeField "established_on" Decode.string)
        |> andMap (maybeField "responsible_person" Decode.string)
        |> andMap (maybeField "registered_address" Decode.string)
        |> andMap (maybeField "tax_registration_notes" Decode.string)
        |> andMap (optionalField "manufacturing_enabled" Decode.bool False)
        |> andMap (optionalField "inventory_item_count" Decode.int 0)
        |> andMap (maybeField "notes" Decode.string)


taiwanFiscalPeriodDecoder : Decoder TaiwanFiscalPeriod
taiwanFiscalPeriodDecoder =
    Decode.succeed TaiwanFiscalPeriod
        |> andMap (Decode.field "id" Decode.string)
        |> andMap (Decode.field "period_start" Decode.string)
        |> andMap (Decode.field "period_end" Decode.string)
        |> andMap (Decode.field "status" Decode.string)
        |> andMap (maybeField "annual_income_tax_due_on" Decode.string)
        |> andMap (maybeField "provisional_income_tax_due_on" Decode.string)
        |> andMap (maybeField "undistributed_earnings_due_on" Decode.string)
        |> andMap (maybeField "notes" Decode.string)


namedOptionDecoder : Decoder NamedOption
namedOptionDecoder =
    Decode.map2 NamedOption
        (Decode.field "id" Decode.string)
        (Decode.field "label" Decode.string)


accountingPeriodDecoder : Decoder AccountingPeriod
accountingPeriodDecoder =
    Decode.succeed AccountingPeriod
        |> andMap (Decode.field "id" Decode.string)
        |> andMap (Decode.field "period_start" Decode.string)
        |> andMap (Decode.field "period_end" Decode.string)
        |> andMap (Decode.field "status" Decode.string)
        |> andMap (maybeField "accounts_due_on" Decode.string)
        |> andMap (maybeField "corporation_tax_due_on" Decode.string)
        |> andMap (maybeField "accounts_filed_on" Decode.string)
        |> andMap (maybeField "ct600_filed_on" Decode.string)
        |> andMap (maybeField "notes" Decode.string)


vatControlAccountOptionDecoder : Decoder VatControlAccountOption
vatControlAccountOptionDecoder =
    Decode.map4 VatControlAccountOption
        (Decode.field "id" Decode.string)
        (Decode.field "name" Decode.string)
        (Decode.field "path" Decode.string)
        (optionalField "selected" Decode.bool False)


configurationCheckDecoder : Decoder ConfigurationCheck
configurationCheckDecoder =
    Decode.map4 ConfigurationCheck
        (Decode.field "id" Decode.string)
        (Decode.field "label" Decode.string)
        (Decode.field "complete" Decode.bool)
        (Decode.map (Maybe.withDefault "") (maybeField "message" Decode.string))


accountDecoder : Decoder Account
accountDecoder =
    Decode.map3 Account
        (Decode.field "book_id" Decode.string)
        (Decode.field "id" Decode.string)
        (Decode.field "asset" Decode.string)


accountSummaryDecoder : Decoder AccountSummary
accountSummaryDecoder =
    Decode.succeed AccountSummary
        |> andMap (Decode.field "book_id" Decode.string)
        |> andMap (Decode.field "id" Decode.string)
        |> andMap (Decode.field "name" Decode.string)
        |> andMap (Decode.field "type" Decode.string)
        |> andMap (Decode.field "asset" Decode.string)
        |> andMap (maybeField "parent_id" Decode.string)
        |> andMap (Decode.field "depth" Decode.int)
        |> andMap (Decode.field "ancestor_ids" (Decode.list Decode.string))
        |> andMap (Decode.field "path" Decode.string)
        |> andMap (Decode.field "has_children" Decode.bool)
        |> andMap (Decode.field "placeholder" Decode.bool)
        |> andMap (Decode.field "account_kind" Decode.string)
        |> andMap (Decode.field "balance" Decode.string)
        |> andMap (Decode.field "subtree_balance" Decode.string)
        |> andMap (Decode.field "subtree_balance_complete" Decode.bool)
        |> andMap (maybeField "reporting_value" Decode.string)
        |> andMap (maybeField "reporting_asset" Decode.string)
        |> andMap (Decode.field "posting_count" Decode.int)
        |> andMap (Decode.field "unreconciled_count" Decode.int)
        |> andMap (Decode.field "is_cash_account" Decode.bool)
        |> Decode.map
            (\account ->
                { account
                    | name = if account.name == "" then account.id else account.name
                    , path = if account.path == "" then account.id else account.path
                }
            )


parentAccountOptionDecoder : Decoder ParentAccountOption
parentAccountOptionDecoder =
    Decode.succeed ParentAccountOption
        |> andMap (Decode.field "id" Decode.string)
        |> andMap (Decode.field "name" Decode.string)
        |> andMap (Decode.field "path" Decode.string)
        |> andMap (Decode.field "type" Decode.string)
        |> andMap (Decode.field "asset" Decode.string)
        |> andMap (optionalField "placeholder" Decode.bool False)


accountKindOptionDecoder : Decoder AccountKindOption
accountKindOptionDecoder =
    Decode.map3 AccountKindOption
        (Decode.field "id" Decode.string)
        (Decode.field "label" Decode.string)
        (maybeField "required_type" Decode.string)


reportOptionDecoder : Decoder ReportOption
reportOptionDecoder =
    Decode.map4 ReportOption
        (Decode.field "id" Decode.string)
        (Decode.field "name" Decode.string)
        (Decode.field "description" Decode.string)
        (Decode.field "report_group" Decode.string)


reportDefinitionDecoder : Decoder ReportDefinition
reportDefinitionDecoder =
    Decode.map5 ReportDefinition
        (Decode.field "report_id" Decode.string)
        (Decode.field "title" Decode.string)
        (Decode.field "description" Decode.string)
        (Decode.field "parameter_kind" Decode.string)
        (Decode.field "reporting_asset" Decode.string)


reportColumnDecoder : Decoder ReportColumn
reportColumnDecoder =
    Decode.map5 ReportColumn
        (Decode.field "column_id" Decode.string)
        (Decode.field "label" Decode.string)
        (Decode.field "alignment" Decode.string)
        (Decode.field "value_format" Decode.string)
        (Decode.field "tree_column" Decode.bool)


genericReportCellDecoder : Decoder GenericReportCell
genericReportCellDecoder =
    Decode.map4 GenericReportCell
        (Decode.field "column_id" Decode.string)
        (maybeField "text" Decode.string)
        (maybeField "exact" Decode.string)
        (maybeField "suffix" Decode.string)


genericReportRowDecoder : Decoder GenericReportRow
genericReportRowDecoder =
    Decode.map4 GenericReportRow
        (Decode.field "row_kind" Decode.string)
        (Decode.field "depth" Decode.int)
        (maybeField "account_id" Decode.string)
        (Decode.field "cells" (Decode.list genericReportCellDecoder))


barChartDefinitionDecoder : Decoder BarChartDefinition
barChartDefinitionDecoder =
    Decode.map4 BarChartDefinition
        (Decode.field "chart_id" Decode.string)
        (Decode.field "title" Decode.string)
        (Decode.field "value_label" Decode.string)
        (Decode.field "value_format" Decode.string)


barChartPointDecoder : Decoder BarChartPoint
barChartPointDecoder =
    Decode.map5 BarChartPoint
        (Decode.field "chart_id" Decode.string)
        (Decode.field "label" Decode.string)
        (maybeField "value" Decode.float)
        (maybeField "exact" Decode.string)
        (maybeField "suffix" Decode.string)


transactionLineDecoder : Decoder TransactionLine
transactionLineDecoder =
    Decode.map3 TransactionLine
        (Decode.field "account" Decode.string)
        (maybeField "comment" Decode.string)
        (Decode.field "amount" Decode.string)


ledgerDecoder : Decoder LedgerEntry
ledgerDecoder =
    Decode.succeed LedgerEntry
        |> andMap (Decode.field "date" Decode.string)
        |> andMap (Decode.field "xid" Decode.int)
        |> andMap (Decode.field "account" Decode.string)
        |> andMap (maybeField "description" Decode.string)
        |> andMap (maybeField "transaction_comment" Decode.string)
        |> andMap (maybeField "transfer" Decode.string)
        |> andMap (Decode.field "amount" Decode.string)
        |> andMap (Decode.field "balance" Decode.string)
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
        |> andMap (maybeField "debit" Decode.string)
        |> andMap (maybeField "credit" Decode.string)


reconciliationEntryDecoder : Decoder ReconciliationEntry
reconciliationEntryDecoder =
    Decode.succeed ReconciliationEntry
        |> andMap (Decode.field "date" Decode.string)
        |> andMap (Decode.field "xid" Decode.int)
        |> andMap (Decode.field "account" Decode.string)
        |> andMap (maybeField "description" Decode.string)
        |> andMap (Decode.field "asset" Decode.string)
        |> andMap (Decode.field "amount" Decode.string)
        |> andMap (Decode.field "reconciled" Decode.bool)


pageContextDecoder : Decoder PageContext
pageContextDecoder =
    Decode.succeed PageContext
        |> andMap (Decode.field "page" Decode.string)
        |> andMap (maybeField "book_id" Decode.string)
        |> andMap (optionalField "book_exists" Decode.bool False)
        |> andMap (optionalField "configuration_status" Decode.string "ordinary")
        |> andMap (maybeField "as_of" Decode.string)
        |> andMap (maybeField "from" Decode.string)
        |> andMap (maybeField "to" Decode.string)
        |> andMap (maybeField "reporting_asset" Decode.string)
        |> andMap (maybeField "account_type" Decode.string)
        |> andMap (maybeField "asset" Decode.string)
        |> andMap (maybeField "parent_id" Decode.string)
        |> andMap (maybeField "account_kind" Decode.string)
        |> andMap (optionalField "placeholder" Decode.bool False)
        |> andMap (maybeField "pretax" Decode.string)
        |> andMap (maybeField "opening_date" Decode.string)
        |> andMap (optionalField "validation_messages" (Decode.list Decode.string) [])


mutationResultDecoder : Decoder MutationResult
mutationResultDecoder =
    Decode.map2 MutationResult
        (Decode.field "book_id" Decode.string)
        (Decode.field "xid" Decode.int)


postingReconciliationDecoder : Decoder PostingReconciliation
postingReconciliationDecoder =
    Decode.map4 PostingReconciliation
        (Decode.field "book_id" Decode.string)
        (Decode.field "xid" Decode.int)
        (Decode.field "account" Decode.string)
        (Decode.field "reconciled" Decode.bool)


draftBalanceDecoder : Decoder DraftBalance
draftBalanceDecoder =
    Decode.map2 DraftBalance
        (Decode.field "asset" Decode.string)
        (Decode.field "amount" Decode.string)


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
                        |> Result.mapError
                            (\error ->
                                Http.BadBody
                                    (String.join "\u{001F}"
                                        [ "decode", Decode.errorToString error ]
                                    )
                            )


databaseError : Int -> String -> String
databaseError status body =
    case Decode.decodeString databaseErrorDecoder body of
        Ok ( message, details ) ->
            String.join "\u{001F}"
                [ "database"
                , String.fromInt status
                , message
                , Maybe.withDefault "" details
                ]

        Err _ ->
            String.join "\u{001F}"
                [ "database-body", String.fromInt status, String.trim body ]


databaseErrorDecoder : Decoder ( String, Maybe String )
databaseErrorDecoder =
    Decode.map2 Tuple.pair
        (Decode.field "message" Decode.string)
        (maybeField "details" Decode.string)


errorToString : Model -> Http.Error -> String
errorToString model err =
    case err of
        Http.BadUrl url ->
            presentationTextWith model "error.bad-url" [ ( "url", url ) ]

        Http.Timeout ->
            presentationText model "error.timeout"

        Http.NetworkError ->
            presentationText model "error.network"

        Http.BadStatus status ->
            presentationTextWith model "error.http-status"
                [ ( "status", String.fromInt status ) ]

        Http.BadBody reason ->
            case String.split "\u{001F}" reason of
                [ "database", status, message, "" ] ->
                    presentationTextWith model "error.database"
                        [ ( "status", status ), ( "message", message ) ]

                [ "database", status, message, details ] ->
                    presentationTextWith model "error.database-detail"
                        [ ( "status", status ), ( "message", message ), ( "details", details ) ]

                [ "database-body", status, body ] ->
                    presentationTextWith model "error.database-body"
                        [ ( "status", status ), ( "body", body ) ]

                [ "decode", details ] ->
                    presentationTextWith model "error.response-invalid"
                        [ ( "details", details ) ]

                _ ->
                    Dict.get reason model.presentation |> Maybe.withDefault reason
