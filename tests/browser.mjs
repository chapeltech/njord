import { chromium } from "playwright";

const base = process.argv[2] || "http://127.0.0.1:8080";
const screenshotDirectory = process.env.NJORD_SCREENSHOT_DIR || "/tmp";
const browser = await chromium.launch({ headless: true });

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

async function waitForInputValue(locator, expected) {
  await locator.evaluate(
    (input, value) =>
      new Promise((resolve, reject) => {
        const deadline = performance.now() + 10_000;
        const check = () => {
          if (input.value === value) resolve();
          else if (performance.now() >= deadline) reject(new Error(`timed out waiting for input value ${value}`));
          else requestAnimationFrame(check);
        };
        check();
      }),
    expected,
  );
}

async function waitForAttribute(locator, name, expected) {
  await locator.evaluate(
    (element, target) =>
      new Promise((resolve, reject) => {
        const deadline = performance.now() + 10_000;
        const check = () => {
          if (element.getAttribute(target.name) === target.value) resolve();
          else if (performance.now() >= deadline) reject(new Error(`timed out waiting for ${target.name}=${target.value}`));
          else requestAnimationFrame(check);
        };
        check();
      }),
    { name, value: expected },
  );
}

async function waitForPaints(page, count = 2) {
  await page.evaluate(
    (remaining) =>
      new Promise((resolve) => {
        const next = () => {
          if (remaining <= 0) resolve();
          else {
            remaining -= 1;
            requestAnimationFrame(next);
          }
        };
        next();
      }),
    count,
  );
}

try {
  for (const [browserLocale, expectedLocale, heading] of [
    ["es-MX", "es-PA", "Libros"],
    ["zh-HK", "zh-TW", "帳簿"],
    ["fr-FR", "en-GB", "Books"],
  ]) {
    const localeContext = await browser.newContext({ locale: browserLocale });
    const localePage = await localeContext.newPage();
    await localePage.goto(base, { waitUntil: "networkidle" });
    await localePage.getByRole("heading", { name: heading, exact: true }).waitFor();
    assert(
      await localePage.locator("html").getAttribute("lang") === expectedLocale,
      `${browserLocale} did not default to ${expectedLocale}`,
    );
    await localeContext.close();
  }

  const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await context.newPage();
  const errors = [];
  let previewRpcRequests = 0;
  let transactionMutationRequests = 0;
  let ledgerPageRequests = 0;
  page.on("console", (message) => {
    if (message.type() === "error" && !message.text().includes("status of 400")) {
      errors.push(message.text());
    }
  });
  page.on("pageerror", (error) => errors.push(error.message));
  page.on("request", (request) => {
    const pathname = new URL(request.url()).pathname;
    if (pathname.endsWith("/rpc/preview_transaction")) previewRpcRequests += 1;
    if (pathname.endsWith("/rpc/ledger_page")) ledgerPageRequests += 1;
    if (pathname.endsWith("/rpc/create_transaction") || pathname.endsWith("/rpc/replace_transaction")) {
      transactionMutationRequests += 1;
    }
  });

  const panelOn = (target, heading) =>
    target.locator("section.panel").filter({
      has: target.getByRole("heading", { name: heading }),
    }).first();
  const panel = (heading) => panelOn(page, heading);
  const waitUntilReadyOn = (target) => target.locator(".status-line").evaluate(
    (status) => new Promise((resolve, reject) => {
      const deadline = performance.now() + 10_000;
      const check = () => {
        if (status.textContent.trim() === "" && !status.querySelector(".busy")) resolve();
        else if (performance.now() >= deadline) reject(new Error(`timed out waiting for ready state: ${status.textContent.trim()}`));
        else requestAnimationFrame(check);
      };
      check();
    }),
  );
  const waitUntilReady = () => waitUntilReadyOn(page);
  const topbarOn = (target) => target.locator(".topbar");
  const topbar = page.locator(".topbar");
  const primaryDestinationOn = (target, name) =>
    topbarOn(target).getByRole("link", { name, exact: true });
  const primaryDestination = (name) => primaryDestinationOn(page, name);
  const assertActiveWorkspaceOn = async (target, expected) => {
    const bookDetail = await target.locator(".book-workspace").count() > 0;
    const destinations = expected === "Admin" || (expected === "Books" && !bookDetail)
      ? ["Admin", "Books"]
      : ["Admin", "Books", "Accounts", "Journal", "Reports"];
    for (const destination of destinations) {
      const current = await primaryDestinationOn(target, destination).getAttribute("aria-current");
      assert(
        current === (destination === expected ? "page" : "false"),
        `${destination} aria-current is ${current} while ${expected} is active`,
      );
    }
  };
  const assertActiveWorkspace = (expected) => assertActiveWorkspaceOn(page, expected);
  const accountLinkOn = (target, account) => {
    const escapedAccount = account.replaceAll("\\", "\\\\").replaceAll('"', '\\"');
    return target
      .locator(
        `section.accounts-index tr.account-tree-row[data-account-id="${escapedAccount}"] a.account-link`,
      )
      .first();
  };
  const reportCard = (scope, name) =>
    scope.locator("a.report-card").filter({
      has: page.getByText(name, { exact: true }),
    }).first();
  const bookCardOn = (target, bookId) =>
    target.locator(`a.book-card[href*="page=book"][href*="book=${bookId}"]`).first();
  const selectBook = async (bookId) => {
    await primaryDestination("Books").click();
    await waitUntilReady();
    await panel("Books").getByRole("heading", { name: "Books", exact: true }).waitFor();
    await bookCardOn(page, bookId).click();
    await waitUntilReady();
    await page.locator(".book-workspace").getByRole("heading", { name: "Book", exact: true }).waitFor();
    await primaryDestination("Accounts").click();
    await waitUntilReady();
  };
  const openBookAdmin = async (bookId) => {
    await primaryDestination("Books").click();
    await waitUntilReady();
    await panel("Books").getByRole("heading", { name: "Books", exact: true }).waitFor();
    await bookCardOn(page, bookId).click();
    await waitUntilReady();
    await page.locator(".book-workspace").getByRole("heading", { name: "Book", exact: true }).waitFor();
  };

  await page.goto(base, { waitUntil: "networkidle" });
  await waitUntilReady();
  await panel("Books").getByRole("heading", { name: "Books", exact: true }).waitFor();
  assert(await topbar.getByLabel("Book").count() === 0, "topbar retains the Book selector");
  const navigationLabels = await topbar.locator(".nav-field > span").allTextContents();
  assert(
    JSON.stringify(navigationLabels) === JSON.stringify([]),
    `topbar retains selector fields: ${navigationLabels.join(" -> ")}`,
  );
  const primaryDestinationLabels = await topbar.locator("a.workspace-tab").allTextContents();
  assert(
    JSON.stringify(primaryDestinationLabels) === JSON.stringify(["Admin", "Books"]),
    `unscoped destinations are ${primaryDestinationLabels.join(" -> ")}`,
  );
  assert(await primaryDestination("Admin").getAttribute("href") === "/?page=admin", "Admin is attached to a Book URL");
  assert(await topbar.getByRole("link", { name: "Accounts", exact: true }).count() === 0, "Books exposes Accounts");
  assert(await topbar.getByRole("link", { name: "Journal", exact: true }).count() === 0, "Books exposes Journal");
  assert(await topbar.getByRole("link", { name: "Reports", exact: true }).count() === 0, "Books exposes Reports");
  assert(await topbar.getByLabel("Report", { exact: true }).count() === 0, "topbar retains the old Report selector");
  assert(await topbar.getByLabel("Account", { exact: true }).count() === 0, "topbar retains the old Account selector");

  const englishLanguageButton = topbar.getByRole("button", { name: "Choose display language" });
  assert(await englishLanguageButton.textContent() === "🇬🇧", "English language trigger is not the UK flag");
  await englishLanguageButton.click();
  const languageMenu = topbar.locator(".language-menu");
  await languageMenu.waitFor();
  await page.waitForFunction(() => document.activeElement?.id === "language-option-en-GB");
  await languageMenu.getByRole("menuitemradio").first().press("ArrowDown");
  await page.waitForFunction(() => document.activeElement?.id === "language-option-es-PA");
  await languageMenu.getByRole("menuitemradio").nth(1).press("Escape");
  await page.waitForFunction(() => document.activeElement?.id === "language-trigger");
  assert(await languageMenu.count() === 0, "Escape did not close the language menu");
  await englishLanguageButton.click();
  await languageMenu.waitFor();
  const languageFlags = await languageMenu.getByRole("menuitemradio").allTextContents();
  assert(
    JSON.stringify(languageFlags) === JSON.stringify(["🇬🇧", "🇵🇦", "🇹🇼"]),
    `language menu is ${JSON.stringify(languageFlags)} instead of the three flags supplied by SQL`,
  );
  const spanishRequest = page.waitForRequest((request) =>
    new URL(request.url()).pathname === "/api/control/rpc/shell_page"
      && request.headers()["accept-language"] === "es-PA",
  );
  await languageMenu.getByRole("menuitemradio").nth(1).click();
  await spanishRequest;
  await page.getByRole("heading", { name: "Libros", exact: true }).waitFor();
  assert(await page.evaluate(() => localStorage.getItem("njord.language")) === "es-PA", "Spanish choice was not persisted");
  assert(await page.locator("html").getAttribute("lang") === "es-PA", "document language did not follow Spanish choice");

  await page.reload({ waitUntil: "networkidle" });
  await page.getByRole("heading", { name: "Libros", exact: true }).waitFor();
  assert(await topbar.getByRole("button", { name: "Elegir idioma de visualización" }).textContent() === "🇵🇦", "stored Spanish was not restored");
  await topbar.getByRole("button", { name: "Elegir idioma de visualización" }).click();
  const englishRequest = page.waitForRequest((request) =>
    new URL(request.url()).pathname === "/api/control/rpc/shell_page"
      && request.headers()["accept-language"] === "en-GB",
  );
  await topbar.locator(".language-menu").getByRole("menuitemradio").first().click();
  await englishRequest;
  await page.getByRole("heading", { name: "Books", exact: true }).waitFor();
  assert(await page.evaluate(() => localStorage.getItem("njord.language")) === "en-GB", "English choice was not persisted");

  const languagePeer = await context.newPage();
  await languagePeer.goto(base, { waitUntil: "networkidle" });
  await languagePeer.getByRole("heading", { name: "Books", exact: true }).waitFor();
  await languagePeer.locator(".language-trigger").click();
  await languagePeer.locator(".language-menu").getByRole("menuitemradio").nth(2).click();
  await page.getByRole("heading", { name: "帳簿", exact: true }).waitFor();
  assert(await page.locator("html").getAttribute("lang") === "zh-TW", "language change did not reach the other browser tab");
  await page.locator(".language-trigger").click();
  await page.locator(".language-menu").getByRole("menuitemradio").first().click();
  await page.getByRole("heading", { name: "Books", exact: true }).waitFor();
  await languagePeer.getByRole("heading", { name: "Books", exact: true }).waitFor();
  await languagePeer.close();

  // The Books page is the global landing page. Choosing a real anchor opens
  // that Book's administration page; accounting destinations then use the
  // same selected Book.
  assert(await bookCardOn(page, "web-test").getAttribute("href") === "/?page=book&book=web-test", "Book card is not a canonical Book-management link");
  const webTestBookResponse = page.waitForResponse((response) => {
    const url = new URL(response.url());
    return url.pathname === "/api/books/web-test/rpc/book_settings_page"
      && response.request().postData()?.includes('"p_book_id":"web-test"');
  });
  await bookCardOn(page, "web-test").click();
  await webTestBookResponse;
  await page.locator(".book-workspace").getByRole("heading", { name: "Book", exact: true }).waitFor();
  await assertActiveWorkspace("Books");
  assert(await topbar.getByRole("link", { name: "Accounts", exact: true }).count() === 1, "Book management hides Accounts");
  assert(await topbar.getByRole("link", { name: "Journal", exact: true }).count() === 1, "Book management hides Journal");
  assert(await topbar.getByRole("link", { name: "Reports", exact: true }).count() === 1, "Book management hides Reports");
  await primaryDestination("Accounts").click();
  await waitUntilReady();

  // Account rows are ordinary links so a ledger is a navigable, shareable destination.
  // ordinary links so a ledger is a navigable, shareable destination.
  const initialAccounts = panel("Accounts");
  await initialAccounts.getByRole("heading", { name: "Accounts", exact: true }).waitFor();
  await assertActiveWorkspace("Accounts");
  assert((await topbar.locator(".active-book-context").textContent()).includes("Web Test · GBP"), "active Book context is missing");
  assert(await primaryDestination("Admin").count() === 1, "Book Admin cannot see the Admin tab");
  const assetsDisclosure = page.locator(
    'section.accounts-index tr[data-account-id="Assets"] button.account-disclosure',
  );
  await assetsDisclosure.waitFor();
  if (await assetsDisclosure.getAttribute("aria-expanded") === "false") {
    await assetsDisclosure.click();
  }
  const currentAccountLink = accountLinkOn(page, "Current Account");
  await currentAccountLink.waitFor();
  const accountTable = initialAccounts.locator("table.accounts-table");
  const accountHeaders = await accountTable.locator("thead th").allTextContents();
  assert(
    JSON.stringify(accountHeaders) === JSON.stringify([
      "Account",
      "Commodity",
      "Native balance",
      "Reporting / market value",
      "Postings",
      "Unreconciled",
    ]),
    `account columns are ${accountHeaders.join(", ")}`,
  );
  const accountTreeRows = accountTable.locator("tbody tr.account-tree-row");
  const accountDepths = await accountTreeRows.evaluateAll((rows) =>
    rows.map((row) => Number(row.dataset.depth)),
  );
  assert(accountDepths.some((depth) => depth > 0), "Accounts index is flat instead of hierarchical");
  const assetsNameBox = await accountTable
    .locator('tr.account-tree-row[data-account-id="Assets"] .account-name')
    .boundingBox();
  const currentAccountNameBox = await currentAccountLink.boundingBox();
  assert(assetsNameBox && currentAccountNameBox, "account hierarchy names have no rendered position");
  assert(
    currentAccountNameBox.x - assetsNameBox.x >= 32,
    `subaccount indentation is only ${currentAccountNameBox.x - assetsNameBox.x}px`,
  );
  const placeholderRows = accountTable.locator('tbody tr.account-tree-row[data-placeholder="true"]');
  assert(await placeholderRows.count() > 0, "Accounts index exposes no placeholder/group accounts");
  assert(
    await placeholderRows.locator("a.account-link").count() === 0,
    "placeholder account links to an empty register",
  );
  const firstDisclosure = assetsDisclosure;
  const expandedRowCount = await accountTreeRows.count();
  await firstDisclosure.click();
  await waitForAttribute(firstDisclosure, "aria-expanded", "false");
  assert(await accountTreeRows.count() < expandedRowCount, "collapsing an account did not hide its descendants");
  await firstDisclosure.click();
  await waitForAttribute(firstDisclosure, "aria-expanded", "true");
  assert(await accountTreeRows.count() === expandedRowCount, "re-expanding an account did not restore its descendants");
  const currentAccountRow = currentAccountLink.locator("xpath=ancestor::tr");
  const currentSubaccountLink = currentAccountRow.getByRole("link", { name: "Add subaccount to Current Account" });
  assert(
    await currentSubaccountLink.getAttribute("href") === "/?page=add-account&book=web-test&account=Current%20Account",
    "Add subaccount is not a canonical parent-aware route",
  );
  const subaccountPopupPromise = context.waitForEvent("page");
  await currentSubaccountLink.click({ button: "middle" });
  const subaccountPopup = await subaccountPopupPromise;
  try {
    await subaccountPopup.waitForLoadState("domcontentloaded");
    const subaccountForm = panelOn(subaccountPopup, "Add account");
    await subaccountForm.getByRole("heading", { name: "Add account", exact: true }).waitFor();
    assert(
      await subaccountForm.getByLabel("Parent account").inputValue() === "Current Account",
      "Add subaccount did not preselect its parent",
    );
    assert(await subaccountForm.getByLabel("Class").isDisabled(), "subaccount class is not inherited from its parent");
    assert(
      await subaccountForm.getByLabel("Commodity").inputValue() === "GBP",
      "subaccount commodity was not inherited from its parent",
    );
  } finally {
    await subaccountPopup.close();
  }
  const accountLinks = page.locator("section.accounts-index a.account-link");
  assert(await accountLinks.count() > 0, "Accounts index exposes no ledger links");
  const accountLinkRoutes = await accountLinks.evaluateAll((links) =>
    links.map((link) => ({ href: link.getAttribute("href"), text: link.textContent })),
  );
  assert(
    accountLinkRoutes.every(({ href }) => {
      const route = new URL(href, base);
      return route.searchParams.get("page") === "ledger"
        && route.searchParams.get("book") === "web-test"
        && route.searchParams.get("account") !== null;
    }),
    `Accounts index contains a non-ledger route: ${JSON.stringify(accountLinkRoutes)}`,
  );
  assert(
    await currentAccountLink.getAttribute("href") === "/?page=ledger&book=web-test&account=Current%20Account",
    "Current Account link is not the canonical encoded ledger URL",
  );
  await currentAccountLink.click();
  await page.getByText("Line updated", { exact: true }).waitFor();
  assert(
    new URL(page.url()).search === "?page=ledger&book=web-test&account=Current%20Account",
    `account-row navigation produced noncanonical URL ${page.url()}`,
  );
  assert((await topbar.locator(".active-book-context").textContent()).includes("Web Test"), "ledger lost active Book context");
  const ledgerPanel = panel("Account ledger");
  const ledgerAccount = ledgerPanel.getByLabel("Account", { exact: true });
  await ledgerAccount.waitFor();
  assert(await ledgerAccount.inputValue() === "Current Account", "Accounts workspace did not select its ledger account");
  assert(await topbar.getByLabel("Account", { exact: true }).count() === 0, "ledger account chooser escaped into the topbar");
  await assertActiveWorkspace("Accounts");
  const assertRegisterNavigationLocked = async (locked, phase) => {
    const controls = [
      ["Admin", primaryDestination("Admin"), "aria"],
      ["Books", primaryDestination("Books"), "aria"],
      ["Accounts", primaryDestination("Accounts"), "aria"],
      ["Journal", primaryDestination("Journal"), "aria"],
      ["Reports", primaryDestination("Reports"), "aria"],
      ["Account", ledgerAccount, "native"],
    ];
    for (const [name, control, kind] of controls) {
      const controlLocked = kind === "aria"
        ? await control.getAttribute("aria-disabled") === "true"
        : await control.isDisabled();
      assert(
        controlLocked === locked,
        `${name} navigation is ${locked ? "unlocked" : "locked"} ${phase}`,
      );
    }
  };
  const ledgerRegister = ledgerPanel.locator(".ledger-register");
  const waitForRpc = (name) =>
    page.waitForResponse((response) => {
      const url = new URL(response.url());
      return url.pathname.endsWith(`/rpc/${name}`) && response.request().method() === "POST";
    });
  const displayedLedgerRow = (description) =>
    ledgerRegister.locator("tbody tr.ledger-line").filter({
      has: page.getByText(description, { exact: true }),
    }).first();
  const ledgerRowByXid = (xid) =>
    ledgerRegister.locator(`tbody tr.ledger-line[data-xid="${xid}"]`);
  const draftBalanceRequests = [];
  let holdFoodFiveBalance = false;
  let heldFoodFiveRoute = null;
  let resolveFoodFiveHeld;
  const foodFiveHeld = new Promise((resolve) => {
    resolveFoodFiveHeld = resolve;
  });
  await page.route("**/rpc/transaction_draft_balance_text", async (route) => {
    const body = route.request().postDataJSON();
    draftBalanceRequests.push(body);
    const food = body.p_lines.find((line) => line.account === "Food");
    if (holdFoodFiveBalance && food?.amount === "5" && heldFoodFiveRoute === null) {
      heldFoodFiveRoute = route;
      resolveFoodFiveHeld();
      return;
    }
    await route.continue();
  });

  const ledgerHeaders = await ledgerRegister.locator("thead th").allTextContents();
  const expectedLedgerHeaders = [
    "Date",
    "Description",
    "Transfer",
    "Deposit",
    "Withdrawal",
    "Balance",
  ];
  assert(
    JSON.stringify(ledgerHeaders) === JSON.stringify(expectedLedgerHeaders),
    `ledger columns are ${ledgerHeaders.join(", ")} instead of ${expectedLedgerHeaders.join(", ")}`,
  );
  assert(await ledgerRegister.getByText("XID", { exact: true }).count() === 0, "ledger exposes internal transaction identifiers");
  assert(await ledgerRegister.getByText("R", { exact: true }).count() === 0, "ledger exposes reconciliation status outside Reconciliation");
  assert(
    await ledgerRegister.getByRole("columnheader", { name: "Actions", exact: true }).count() === 0,
    "ledger restored its migration-era Actions column",
  );
  assert(
    await ledgerRegister
      .locator("tbody tr.ledger-line")
      .getByRole("button", { name: /^(Line|Transaction|Details|Hide)$/ })
      .count() === 0,
    "ledger rows restored migration-era action buttons",
  );
  assert(await ledgerRegister.locator("button").count() === 0, "ledger register exposes inline action buttons");
  assert(await ledgerRegister.locator("tr.register-controls-row").count() === 0, "ledger register exposes a separate controls row");
  assert(
    await page.locator(".ledger-edit-panel:visible, .transaction-editor:visible").count() === 0,
    "ledger editing escaped into a detached editor",
  );
  assert(
    await ledgerPanel.getByRole("button", { name: "New transaction", exact: true }).count() === 0,
    "new transactions escaped from the register footer",
  );

  const ledgerAppearance = await ledgerRegister.evaluate((table) => {
    const header = table.querySelector("thead th");
    const row = table.querySelector("tbody .ledger-line");
    const amount = table.querySelector("tbody .ledger-deposit, tbody .ledger-withdrawal");
    const green = table.querySelector("tbody .ledger-line-green td");
    const yellow = table.querySelector("tbody .ledger-line-yellow td");
    if (!header || !row || !amount || !green || !yellow) return null;
    const headerStyle = getComputedStyle(header);
    const amountStyle = getComputedStyle(amount);
    return {
      fontFamily: getComputedStyle(table).fontFamily,
      headerBackground: headerStyle.backgroundColor,
      rowHeight: row.getBoundingClientRect().height,
      amountAlignment: amountStyle.textAlign,
      amountNumerals: amountStyle.fontVariantNumeric,
      gridWidth: amountStyle.borderRightWidth,
      gridStyle: amountStyle.borderRightStyle,
      greenBackground: getComputedStyle(green).backgroundColor,
      yellowBackground: getComputedStyle(yellow).backgroundColor,
      cellWhiteSpace: amountStyle.whiteSpace,
    };
  });
  assert(ledgerAppearance !== null, "ledger register is missing its semantic row classes");
  assert(ledgerAppearance.fontFamily.includes("Arial"), "ledger register lost its compact accounting typeface");
  assert(ledgerAppearance.headerBackground === "rgb(150, 177, 131)", "ledger register header lost its green band");
  assert(ledgerAppearance.rowHeight <= 34, `ledger rows are no longer compact (${ledgerAppearance.rowHeight}px)`);
  assert(ledgerAppearance.amountAlignment === "right", "ledger amounts are not right aligned");
  assert(ledgerAppearance.amountNumerals.includes("tabular-nums"), "ledger amounts lost tabular numerals");
  assert(ledgerAppearance.gridWidth === "1px" && ledgerAppearance.gridStyle === "solid", "ledger register lost its cell grid");
  assert(ledgerAppearance.greenBackground === "rgb(191, 222, 185)", "ledger green transaction band is missing");
  assert(ledgerAppearance.yellowBackground === "rgb(255, 239, 152)", "ledger yellow transaction band is missing");
  assert(ledgerAppearance.cellWhiteSpace === "nowrap", "ledger cells no longer resist wrapping");

  // Primary workspaces are real anchors. Middle-click each one and prove the
  // new browser page restores the same book and a functional destination while
  // leaving this ledger tab untouched.
  const ledgerUrlBeforeNewTabs = page.url();
  const workspaceDestinations = [
    ["Admin", "Admin"],
    ["Books", "Books"],
    ["Accounts", "Accounts"],
    ["Journal", "General Journal"],
    ["Reports", "Reports"],
  ];
  const openByMiddleClick = async (link) => {
    const expectedUrl = new URL(await link.getAttribute("href"), page.url()).toString();
    const popupPromise = page.context().waitForEvent("page");
    await link.click({ button: "middle" });
    const popup = await popupPromise;
    await popup.waitForURL(expectedUrl);
    await popup.waitForLoadState("domcontentloaded");
    await waitUntilReadyOn(popup);
    return popup;
  };
  for (const [workspace, heading] of workspaceDestinations) {
    const link = primaryDestination(workspace);
    const href = await link.getAttribute("href");
    const expectedHref = workspace === "Books"
      ? "/?page=books"
      : workspace === "Admin"
        ? "/?page=admin"
        : `/?page=${workspace.toLowerCase()}&book=web-test`;
    assert(href === expectedHref, `${workspace} has noncanonical href ${href}`);
    const popup = await openByMiddleClick(link);
    try {
      await assertActiveWorkspaceOn(popup, workspace);
      if (workspace === "Admin") {
        assert((await topbarOn(popup).locator(".active-book-context").textContent()).trim() === "", "Admin new tab retained a Book context");
        await panelOn(popup, heading).getByRole("heading", { name: heading, exact: true }).waitFor();
        await panelOn(popup, heading).locator("table.global-users-table tbody tr").first().waitFor();
        assert(await panelOn(popup, heading).getByRole("columnheader", { name: "Actions", exact: true }).count() === 1, "Admin does not render SQL-owned user actions");
      } else if (workspace === "Books") {
        await panelOn(popup, heading).getByRole("heading", { name: heading, exact: true }).waitFor();
        await bookCardOn(popup, "web-test").waitFor();
      } else if (workspace === "Accounts") {
        assert((await topbarOn(popup).locator(".active-book-context").textContent()).includes("Web Test"), "Accounts new tab lost the active Book");
        await panelOn(popup, heading).getByRole("heading", { name: heading, exact: true }).waitFor();
        await accountLinkOn(popup, "Current Account").waitFor();
      } else if (workspace === "Journal") {
        await panelOn(popup, heading).getByRole("heading", { name: heading, exact: true }).waitFor();
        await panelOn(popup, heading).locator("tbody tr").first().waitFor();
      } else {
        await panelOn(popup, heading).getByRole("heading", { name: heading, exact: true }).waitFor();
        assert(await panelOn(popup, "Reports").locator("a.report-card").count() === 5, "Reports new tab has no functional report library");
      }
    } finally {
      await popup.close();
    }
  }
  assert(page.url() === ledgerUrlBeforeNewTabs, "middle-clicking workspace links navigated the source ledger tab");
  await displayedLedgerRow("Line updated").waitFor();

  // Every canonical URL restores its book, account where applicable, active
  // workspace, and selected report without depending on in-memory navigation.
  const directRoutes = [
    ["/?page=books", "Books", "Books", null],
    ["/?page=admin", "Admin", "Admin", null],
    ["/?page=book&book=web-test", "Books", "Book", null],
    ["/?page=accounts&book=web-test", "Accounts", "Accounts", null],
    ["/?page=ledger&book=web-test&account=Current%20Account", "Accounts", "Account ledger", "Current Account"],
    ["/?page=journal&book=web-test", "Journal", "General Journal", null],
    ["/?page=reconciliation&book=web-test&account=Food", "Accounts", "Reconciliation", "Food"],
    ["/?page=reports&book=web-test", "Reports", "Reports", null],
    ["/?page=report&book=web-test&report=balance-sheet", "Reports", "Balance Sheet", null],
    ["/?page=report&book=web-test&report=net-worth", "Reports", "Net Worth", null],
    ["/?page=report&book=web-test&report=trial-balance", "Reports", "Trial Balance", null],
    ["/?page=report&book=web-test&report=profit-loss", "Reports", "Profit & Loss", null],
    ["/?page=report&book=web-test&report=cash-flow", "Reports", "Cash Flow", null],
  ];
  for (const [route, workspace, heading, account] of directRoutes) {
    const directPage = await page.context().newPage();
    try {
      await directPage.goto(new URL(route, base).toString(), { waitUntil: "domcontentloaded" });
      await waitUntilReadyOn(directPage);
      if (workspace !== "Books" && route !== "/?page=admin") {
        const activeBookContext = topbarOn(directPage).locator(".active-book-context");
        await activeBookContext.filter({ hasText: "Web Test" }).waitFor();
        assert((await activeBookContext.textContent()).includes("Web Test"), `${route} did not restore its Book context`);
      }
      await assertActiveWorkspaceOn(directPage, workspace);
      const directPanel = route.includes("page=book&")
        ? directPage.locator(".book-workspace")
        : panelOn(directPage, heading);
      await directPanel.getByRole("heading", { name: heading, exact: true }).waitFor();
      if (route.includes("page=admin")) {
        assert(new URL(directPage.url()).searchParams.get("book") === null, `${route} attached Admin to a Book`);
        await directPanel.locator("table.global-users-table tbody tr").first().waitFor();
      } else if (route.includes("page=book&")) {
        assert(await directPanel.getByLabel("Book name").inputValue() === "Web Test", `${route} did not restore its book settings`);
      } else if (route.includes("page=books")) {
        await bookCardOn(directPage, "web-test").waitFor();
      } else if (route.includes("page=accounts")) {
        await accountLinkOn(directPage, "Current Account").waitFor();
      } else if (route.includes("page=ledger")) {
        assert(await directPanel.getByLabel("Account", { exact: true }).inputValue() === account, `${route} did not restore its ledger account`);
        await directPanel.getByText("Line updated", { exact: true }).waitFor();
      } else if (route.includes("page=reconciliation")) {
        assert(await directPanel.getByLabel("Account filter").inputValue() === account, `${route} did not restore its reconciliation account`);
        await directPanel.locator('tbody tr.reconciliation-row[data-account="Food"]').first().waitFor();
      } else if (route.includes("page=reports")) {
        assert(await directPanel.locator("a.report-card").count() === 5, `${route} did not restore the report library`);
      } else {
        await directPanel.locator("tbody tr").first().waitFor();
      }
    } finally {
      await directPage.close();
    }
  }

  // A page RPC that never answers must not trap the entire application. Keep
  // Book and the primary workspaces available, cancel the stale request, and
  // accept only the response belonging to the latest selection.
  let stalledBalanceRoute;
  const stallBalanceSheet = async (route) => {
    if (route.request().postDataJSON().p_report_id === "balance-sheet") {
      stalledBalanceRoute = route;
    } else {
      await route.continue();
    }
  };
  await page.route("**/rpc/report_page", stallBalanceSheet);
  await primaryDestination("Reports").click();
  const stalledReportLibrary = panel("Reports");
  await stalledReportLibrary.getByRole("heading", { name: "Reports", exact: true }).waitFor();
  await assertActiveWorkspace("Reports");
  await reportCard(stalledReportLibrary, "Balance Sheet").click();
  await page.locator(".status-line").getByText("Loading report", { exact: true }).waitFor();
  for (const destination of ["Admin", "Books", "Accounts", "Journal", "Reports"]) {
    assert(
      await primaryDestination(destination).getAttribute("aria-disabled") === "false",
      `${destination} navigation is locked by a pending page request`,
    );
  }
  assert(await topbar.getByLabel("Account", { exact: true }).count() === 0, "a book-level report exposes an irrelevant topbar account selector");
  await primaryDestination("Accounts").click();
  await waitUntilReady();
  await panel("Accounts").getByRole("heading", { name: "Accounts", exact: true }).waitFor();
  await accountLinkOn(page, "Current Account").click();
  await page.getByText("Line updated", { exact: true }).waitFor();
  await ledgerAccount.waitFor();
  await assertActiveWorkspace("Accounts");
  if (stalledBalanceRoute) await stalledBalanceRoute.abort().catch(() => {});
  await page.unroute("**/rpc/report_page", stallBalanceSheet);

  // Clicking a register row turns that row into the transaction editor. Escape
  // restores only the focused field, while Enter commits the transaction and
  // folds it back into its compact display row.
  const originalReadRow = displayedLedgerRow("Line updated");
  const originalXid = await originalReadRow.getAttribute("data-xid");
  assert(originalXid !== null, "editable ledger row has no transaction identifier");
  await originalReadRow.locator(".ledger-description").click();
  const originalRow = ledgerRowByXid(originalXid);
  await originalRow.getByLabel("Description").waitFor();
  assert(await originalRow.getAttribute("class").then((value) => value.includes("ledger-row-selected")), "clicked ledger row is not selected");
  assert(await ledgerRegister.locator("tbody tr.ledger-line.ledger-row-selected").count() === 1, "ledger selected more than one parent row");
  assert(await originalRow.getByLabel("Date").inputValue() === "2026-02-04", "inline date did not preserve SQL data");
  assert(await originalRow.getByLabel("Description").inputValue() === "Line updated", "inline description did not preserve the transaction header");
  assert(await originalRow.getByLabel("Transfer").inputValue() === "Food", "inline transfer did not preserve its account");
  assert(await originalRow.getByLabel("Transfer").locator('option[value=""]').count() === 0, "existing transfer can be reset to Select account");
  assert(await originalRow.getByLabel("Deposit").inputValue() === "", "withdrawal appeared in the Deposit field");
  assert(await originalRow.getByLabel("Withdrawal").inputValue() === "15.00000", "inline Withdrawal did not preserve its exact amount");
  assert(await originalRow.locator("button").count() === 0, "simple inline edit exposes action buttons");

  const mutationsBeforeEscape = transactionMutationRequests;
  const originalDescription = originalRow.getByLabel("Description");
  await originalDescription.fill("Discard this field edit");
  await assertRegisterNavigationLocked(true, "while a register draft is dirty");
  await waitForPaints(page);
  assert(await originalDescription.inputValue() === "Discard this field edit", "locking navigation discarded the dirty register draft");
  await originalDescription.press("Escape");
  await page.locator(".status-line").getByText("Field edit cancelled", { exact: true }).waitFor();
  await waitForInputValue(originalDescription, "Line updated");
  assert(await originalDescription.inputValue() === "Line updated", "Escape did not restore the focused field");
  assert(
    await originalRow.getAttribute("class").then((value) => value.includes("ledger-row-selected")),
    "Escape closed the transaction instead of leaving its row open",
  );
  assert(transactionMutationRequests === mutationsBeforeEscape, "Escape wrote the transaction instead of reverting the field locally");
  await assertRegisterNavigationLocked(false, "after cancelling the only dirty field");

  // Replace a simple transaction by pressing Enter. PostgreSQL receives the
  // simple intent and supplies its reciprocal posting.
  await originalDescription.fill("Browser replacement");
  const replacementResponsePromise = waitForRpc("replace_transaction");
  await originalDescription.press("Enter");
  const replacementResponse = await replacementResponsePromise;
  assert(replacementResponse.ok(), `inline replacement returned HTTP ${replacementResponse.status()}`);
  const replacementRequest = replacementResponse.request().postDataJSON();
  assert(replacementRequest.p_book_id === "web-test", "inline replacement targeted the wrong book");
  assert(String(replacementRequest.p_xid) === originalXid, "inline replacement targeted the wrong transaction");
  assert("simple" in replacementRequest.p_transaction, "simple inline edit bypassed SQL simple-transaction normalization");
  assert(!("lines" in replacementRequest.p_transaction), "simple inline edit performed client-side counterline accounting");
  const savedOriginalRow = ledgerRowByXid(originalXid);
  await displayedLedgerRow("Browser replacement").waitFor();
  assert(await savedOriginalRow.locator("input, select").count() === 0, "Enter left the saved simple transaction open");
  assert(
    !(await savedOriginalRow.getAttribute("class").then((value) => value.includes("ledger-row-selected"))),
    "Enter did not fold the saved simple transaction",
  );
  await assertRegisterNavigationLocked(false, "after the saved transaction's canonical refresh");

  // Description-only edits must not round an exact PostgreSQL NUMERIC while
  // the transaction passes through the browser.
  const precisionReadRow = displayedLedgerRow("Precision fixture");
  const precisionXid = await precisionReadRow.getAttribute("data-xid");
  assert(precisionXid !== null, "precision fixture has no transaction identifier");
  await precisionReadRow.locator(".ledger-description").click();
  const precisionRow = ledgerRowByXid(precisionXid);
  const precisionDescription = precisionRow.getByLabel("Description");
  assert(
    await precisionRow.getByLabel("Withdrawal").inputValue() === "9007199254740993.00001",
    "precision fixture was rounded while opening the inline editor",
  );
  await precisionDescription.fill("Precision fixture renamed");
  const dirtyLanguagePeer = await context.newPage();
  await dirtyLanguagePeer.goto(base, { waitUntil: "networkidle" });
  await dirtyLanguagePeer.getByRole("heading", { name: "Books", exact: true }).waitFor();
  await dirtyLanguagePeer.locator(".language-trigger").click();
  await dirtyLanguagePeer.locator(".language-menu").getByRole("menuitemradio").nth(2).click();
  await dirtyLanguagePeer.getByRole("heading", { name: "帳簿", exact: true }).waitFor();
  await waitForPaints(page);
  assert(await page.locator("html").getAttribute("lang") === "en-GB", "dirty tab changed document language before accepting the SQL vocabulary");
  const precisionResponsePromise = waitForRpc("replace_transaction");
  await precisionDescription.press("Enter");
  const precisionResponse = await precisionResponsePromise;
  assert(precisionResponse.ok(), `precision replacement returned HTTP ${precisionResponse.status()}`);
  const precisionRequest = precisionResponse.request().postDataJSON();
  assert(
    precisionRequest.p_transaction.simple.amount === "-9007199254740993.00001",
    `description-only edit rounded exact amount to ${precisionRequest.p_transaction.simple.amount}`,
  );
  await page.waitForFunction(() => document.documentElement.lang === "zh-TW");
  await dirtyLanguagePeer.locator(".language-trigger").click();
  await dirtyLanguagePeer.locator(".language-menu").getByRole("menuitemradio").first().click();
  await page.waitForFunction(() => document.documentElement.lang === "en-GB");
  await waitUntilReady();
  await dirtyLanguagePeer.close();
  await displayedLedgerRow("Precision fixture renamed").waitFor();

  // A persisted three-line fixture expands into every posting, including the
  // current account posting, followed by GnuCash's permanent blank split row.
  const splitReadRow = displayedLedgerRow("Browser split fixture");
  const splitXid = await splitReadRow.getAttribute("data-xid");
  assert(splitXid !== null, "split fixture has no transaction identifier");
  await splitReadRow.locator(".ledger-description").click();
  const splitParent = ledgerRowByXid(splitXid);
  await splitParent.getByLabel("Description").waitFor();
  const splitRows = ledgerRegister.locator(`tbody tr.ledger-split-line[data-xid="${splitXid}"]`);
  const populatedSplitRows = ledgerRegister.locator(`tbody tr.ledger-split-line[data-xid="${splitXid}"][data-draft="line"]`);
  const blankSplitRows = ledgerRegister.locator(`tbody tr.ledger-split-line[data-xid="${splitXid}"][data-draft="blank"]`);
  await populatedSplitRows.first().getByLabel("Account").waitFor();
  assert(await populatedSplitRows.count() === 3, `split fixture exposed ${await populatedSplitRows.count()} postings instead of 3`);
  assert(await blankSplitRows.count() === 1, "split fixture has no single permanent blank row");
  const splitAccounts = await populatedSplitRows.getByLabel("Account").evaluateAll((selects) => selects.map((select) => select.value));
  assert(
    JSON.stringify(splitAccounts) === JSON.stringify(["Current Account", "Food", "Fees"]),
    `split accounts are ${splitAccounts.join(", ")}`,
  );
  assert(await populatedSplitRows.nth(0).getByLabel("Withdrawal").inputValue() === "20.00000", "current-account split amount was not restored");
  assert(await populatedSplitRows.nth(1).getByLabel("Memo").inputValue() === "Food share", "first remote split memo was not restored");
  assert(await populatedSplitRows.nth(2).getByLabel("Memo").inputValue() === "Fee share", "second remote split memo was not restored");
  assert(await populatedSplitRows.nth(1).getByLabel("Deposit").inputValue() === "15.00000", "first remote split amount was not restored");
  assert(await populatedSplitRows.nth(2).getByLabel("Deposit").inputValue() === "5.00000", "second remote split amount was not restored");
  assert(await populatedSplitRows.getByLabel("Account").locator('option[value=""]').count() === 0, "persisted split posting can be reset to Select account");
  assert(await blankSplitRows.getByLabel("Blank split account").inputValue() === "", "permanent split row is not blank");
  assert(await splitRows.locator("button").count() === 0, "expanded split transaction exposes action buttons");
  const splitSequence = await splitParent.evaluate((row) => {
    const children = [];
    let sibling = row.nextElementSibling;
    while (sibling?.classList.contains("ledger-split-line")) {
      children.push({ xid: sibling.dataset.xid, draft: sibling.dataset.draft });
      sibling = sibling.nextElementSibling;
    }
    return children;
  });
  assert(
    JSON.stringify(splitSequence) === JSON.stringify([
      { xid: splitXid, draft: "line" },
      { xid: splitXid, draft: "line" },
      { xid: splitXid, draft: "line" },
      { xid: splitXid, draft: "blank" },
    ]),
    "split fixture lines are not contiguous siblings of their parent",
  );
  const splitAppearance = await populatedSplitRows.first().evaluate((row) => ({
    background: getComputedStyle(row.children[3]).backgroundColor,
    emptyDateBackground: getComputedStyle(row.children[0]).backgroundColor,
    height: row.getBoundingClientRect().height,
  }));
  assert(splitAppearance.background === "rgb(237, 231, 211)", "ledger split lines lost their beige detail band");
  assert(splitAppearance.emptyDateBackground === "rgb(246, 245, 244)", "ledger split date gutter is not visually empty");
  assert(splitAppearance.height <= 32, `ledger split rows are no longer compact (${splitAppearance.height}px)`);

  const splitMutationsBeforeEscape = transactionMutationRequests;
  const feeMemo = ledgerRegister.locator(`tbody tr.ledger-split-line[data-xid="${splitXid}"][data-account="Fees"]`).getByLabel("Memo");
  await feeMemo.fill("Discard this split memo");
  await feeMemo.press("Escape");
  await waitForInputValue(feeMemo, "Fee share");
  assert(await feeMemo.inputValue() === "Fee share", "Escape did not restore the focused split field");
  assert(await populatedSplitRows.count() === 3 && await blankSplitRows.count() === 1, "Escape closed or damaged the expanded split");
  assert(transactionMutationRequests === splitMutationsBeforeEscape, "Escape wrote the expanded split transaction");

  // Clean row-to-row navigation is entirely local. It retains the register DOM
  // and both scroll axes without issuing a mutation or a page reload.
  await page.setViewportSize({ width: 900, height: 500 });
  const cleanARead = displayedLedgerRow("Navigation fixture 01");
  const cleanBRead = displayedLedgerRow("Navigation fixture 02");
  const cleanCRead = displayedLedgerRow("Navigation fixture 03");
  const cleanAXid = await cleanARead.getAttribute("data-xid");
  const cleanBXid = await cleanBRead.getAttribute("data-xid");
  const cleanCXid = await cleanCRead.getAttribute("data-xid");
  assert(cleanAXid !== null && cleanBXid !== null && cleanCXid !== null, "clean-navigation fixtures have no transaction identifiers");
  await cleanARead.locator(".ledger-description").click();
  await ledgerRowByXid(cleanAXid).getByLabel("Description").waitFor();
  await ledgerRowByXid(cleanBXid).evaluate((row) => {
    const top = window.scrollY + row.getBoundingClientRect().top;
    window.scrollTo(0, Math.max(1, top - (window.innerHeight / 2)));
  });
  await ledgerPanel.evaluate((panelElement) => { panelElement.scrollLeft = 100; });
  await page.evaluate(() => { window.__cleanLedgerTable = document.querySelector(".ledger-register"); });
  const cleanGeometryBefore = await page.evaluate(() => ({
    scrollTop: document.scrollingElement.scrollTop,
    scrollLeft: document.querySelector(".ledger-panel").scrollLeft,
    documentHeight: document.scrollingElement.scrollHeight,
  }));
  const cleanMutationBaseline = transactionMutationRequests;
  const cleanPageBaseline = ledgerPageRequests;
  await cleanBRead.locator(".ledger-description").click();
  await ledgerRowByXid(cleanBXid).getByLabel("Description").waitFor();
  await ledgerRowByXid(cleanCXid).locator(".ledger-description").click();
  await ledgerRowByXid(cleanCXid).getByLabel("Description").waitFor();
  await waitForPaints(page);
  const cleanGeometryAfter = await page.evaluate(() => ({
    sameTable: window.__cleanLedgerTable === document.querySelector(".ledger-register"),
    scrollTop: document.scrollingElement.scrollTop,
    scrollLeft: document.querySelector(".ledger-panel").scrollLeft,
    documentHeight: document.scrollingElement.scrollHeight,
    loadingPanels: document.querySelectorAll(".loading-panel").length,
  }));
  assert(transactionMutationRequests === cleanMutationBaseline, "clean row navigation issued a transaction mutation");
  assert(ledgerPageRequests === cleanPageBaseline, "clean row navigation reloaded the ledger page");
  assert(cleanGeometryAfter.sameTable, "clean row navigation replaced the ledger table");
  assert(cleanGeometryAfter.loadingPanels === 0, "clean row navigation exposed a loading panel");
  assert(Math.abs(cleanGeometryAfter.scrollTop - cleanGeometryBefore.scrollTop) <= 1, "clean row navigation changed vertical scroll");
  assert(Math.abs(cleanGeometryAfter.scrollLeft - cleanGeometryBefore.scrollLeft) <= 1, "clean row navigation changed horizontal scroll");
  assert(Math.abs(cleanGeometryAfter.documentHeight - cleanGeometryBefore.documentHeight) <= 2, "clean row navigation changed register height");

  // A dirty A -> B switch saves A before activating B. Hold both network
  // boundaries and sample every animation frame: the same table must remain
  // connected, visible, populated, and in the same scroll position throughout.
  const dirtyARead = displayedLedgerRow("Navigation fixture 10");
  const dirtyBRead = displayedLedgerRow("Navigation fixture 11");
  const dirtyCRead = displayedLedgerRow("Navigation fixture 12");
  const dirtyAXid = await dirtyARead.getAttribute("data-xid");
  const dirtyBXid = await dirtyBRead.getAttribute("data-xid");
  const dirtyCXid = await dirtyCRead.getAttribute("data-xid");
  assert(dirtyAXid !== null && dirtyBXid !== null && dirtyCXid !== null, "dirty-navigation fixtures have no transaction identifiers");
  await dirtyARead.locator(".ledger-description").click();
  const dirtyARow = ledgerRowByXid(dirtyAXid);
  const dirtyADescription = dirtyARow.getByLabel("Description");
  await dirtyADescription.waitFor();
  await dirtyADescription.fill("Navigation fixture 10 saved");
  await ledgerRowByXid(dirtyBXid).evaluate((row) => {
    const top = window.scrollY + row.getBoundingClientRect().top;
    window.scrollTo(0, Math.max(1, top - (window.innerHeight / 2)));
  });
  await ledgerPanel.evaluate((panelElement) => { panelElement.scrollLeft = 100; });

  let heldReplaceRoute;
  let resolveReplaceHeld;
  const replaceHeld = new Promise((resolve) => { resolveReplaceHeld = resolve; });
  const stallReplace = (route) => {
    heldReplaceRoute = route;
    resolveReplaceHeld();
  };
  let heldLedgerRoute;
  let resolveLedgerHeld;
  const ledgerHeld = new Promise((resolve) => { resolveLedgerHeld = resolve; });
  const stallLedger = (route) => {
    heldLedgerRoute = route;
    resolveLedgerHeld();
  };
  await page.route("**/rpc/replace_transaction", stallReplace);
  await page.route("**/rpc/ledger_page", stallLedger);

  const continuityBefore = await page.evaluate(() => {
    const table = document.querySelector(".ledger-register");
    const panelElement = document.querySelector(".ledger-panel");
    const state = {
      table,
      header: table.querySelector("thead"),
      panel: panelElement,
      active: true,
      removed: false,
      loadingSeen: false,
      samples: [],
      initialScrollTop: document.scrollingElement.scrollTop,
      initialScrollLeft: panelElement.scrollLeft,
      initialDocumentHeight: document.scrollingElement.scrollHeight,
      initialRowCount: table.querySelectorAll("tbody tr").length,
    };
    state.observer = new MutationObserver(() => {
      if (!state.table.isConnected) state.removed = true;
      if (document.querySelector(".loading-panel")) state.loadingSeen = true;
    });
    state.observer.observe(document.querySelector(".page-shell"), { childList: true, subtree: true });
    const sample = () => {
      if (!state.active) return;
      state.samples.push({
        connected: state.table.isConnected,
        visible: state.table.getClientRects().length > 0,
        rowCount: state.table.querySelectorAll("tbody tr").length,
        scrollTop: document.scrollingElement.scrollTop,
        scrollLeft: state.panel.scrollLeft,
        documentHeight: document.scrollingElement.scrollHeight,
        loading: Boolean(document.querySelector(".loading-panel")),
      });
      requestAnimationFrame(sample);
    };
    window.__ledgerContinuity = state;
    requestAnimationFrame(sample);
    return {
      scrollTop: state.initialScrollTop,
      scrollLeft: state.initialScrollLeft,
      documentHeight: state.initialDocumentHeight,
      rowCount: state.initialRowCount,
    };
  });
  assert(continuityBefore.scrollTop > 0, "dirty-navigation fixture did not create vertical scroll");
  assert(continuityBefore.scrollLeft > 0, "dirty-navigation fixture did not create horizontal scroll");

  const dirtyMutationBaseline = transactionMutationRequests;
  const dirtyPageBaseline = ledgerPageRequests;
  const replaceResponsePromise = waitForRpc("replace_transaction");
  await dirtyBRead.locator(".ledger-description").click();
  await replaceHeld;
  await ledgerRowByXid(dirtyCXid).locator(".ledger-description").click();
  await ledgerRowByXid(dirtyBXid).locator(".ledger-description").click();
  await waitForPaints(page);
  assert(transactionMutationRequests === dirtyMutationBaseline + 1, "repeated clicks during save issued duplicate mutations");
  assert(ledgerPageRequests === dirtyPageBaseline, "ledger reload started before the save succeeded");

  await heldReplaceRoute.continue();
  const replaceResponse = await replaceResponsePromise;
  assert(replaceResponse.ok(), `dirty row replacement returned HTTP ${replaceResponse.status()}`);
  await ledgerHeld;
  await ledgerRowByXid(dirtyCXid).locator(".ledger-description").click();
  await ledgerRowByXid(dirtyBXid).locator(".ledger-description").click();
  await waitForPaints(page);
  assert(transactionMutationRequests === dirtyMutationBaseline + 1, "repeated clicks during refresh issued duplicate mutations");
  assert(ledgerPageRequests === dirtyPageBaseline + 1, "dirty row navigation did not issue one canonical ledger reload");

  const continuityDuring = await page.evaluate(() => ({
    sameTable: window.__ledgerContinuity.table === document.querySelector(".ledger-register"),
    sameHeader: window.__ledgerContinuity.header === document.querySelector(".ledger-register thead"),
    connected: window.__ledgerContinuity.table.isConnected,
    visible: window.__ledgerContinuity.table.getClientRects().length > 0,
    rowCount: window.__ledgerContinuity.table.querySelectorAll("tbody tr").length,
    scrollTop: document.scrollingElement.scrollTop,
    scrollLeft: window.__ledgerContinuity.panel.scrollLeft,
    documentHeight: document.scrollingElement.scrollHeight,
    loadingPanels: document.querySelectorAll(".loading-panel").length,
  }));
  assert(continuityDuring.sameTable && continuityDuring.sameHeader, "pending dirty navigation replaced the ledger DOM");
  assert(continuityDuring.connected && continuityDuring.visible, "pending dirty navigation hid or disconnected the ledger");
  assert(continuityDuring.rowCount === continuityBefore.rowCount, "pending dirty navigation removed ledger rows");
  assert(continuityDuring.loadingPanels === 0, "pending dirty navigation exposed a loading panel");
  assert(
    Math.abs(continuityDuring.scrollTop - continuityBefore.scrollTop) <= 1,
    `pending dirty navigation changed vertical scroll (${continuityBefore.scrollTop} -> ${continuityDuring.scrollTop})`,
  );
  assert(Math.abs(continuityDuring.scrollLeft - continuityBefore.scrollLeft) <= 1, "pending dirty navigation changed horizontal scroll");
  assert(Math.abs(continuityDuring.documentHeight - continuityBefore.documentHeight) <= 2, "pending dirty navigation collapsed document height");

  const ledgerResponsePromise = waitForRpc("ledger_page");
  await heldLedgerRoute.continue();
  const ledgerResponse = await ledgerResponsePromise;
  assert(ledgerResponse.ok(), `canonical ledger reload returned HTTP ${ledgerResponse.status()}`);
  const dirtyBRow = ledgerRowByXid(dirtyBXid);
  await dirtyBRow.getByLabel("Description").waitFor();
  await displayedLedgerRow("Navigation fixture 10 saved").waitFor();
  await waitForPaints(page);
  const continuityAfter = await page.evaluate(() => {
    const state = window.__ledgerContinuity;
    state.active = false;
    state.observer.disconnect();
    return {
      sameTable: state.table === document.querySelector(".ledger-register"),
      sameHeader: state.header === document.querySelector(".ledger-register thead"),
      removed: state.removed,
      loadingSeen: state.loadingSeen,
      samples: state.samples,
      scrollTop: document.scrollingElement.scrollTop,
      scrollLeft: state.panel.scrollLeft,
      documentHeight: document.scrollingElement.scrollHeight,
      selectedXid: document.querySelector(".ledger-row-selected")?.dataset.xid,
    };
  });
  assert(continuityAfter.sameTable && continuityAfter.sameHeader, "canonical dirty navigation replaced the ledger DOM");
  assert(!continuityAfter.removed, "ledger table was disconnected during dirty navigation");
  assert(!continuityAfter.loadingSeen, "a loading panel flashed during dirty navigation");
  assert(continuityAfter.samples.length > 0, "dirty navigation produced no painted-frame samples");
  assert(
    continuityAfter.samples.every((sample) => sample.connected && sample.visible && !sample.loading && sample.rowCount === continuityBefore.rowCount),
    "one or more painted frames lost the visible populated ledger",
  );
  assert(
    continuityAfter.samples.every((sample) => Math.abs(sample.scrollTop - continuityBefore.scrollTop) <= 1),
    "one or more painted frames changed vertical scroll",
  );
  assert(
    continuityAfter.samples.every((sample) => Math.abs(sample.scrollLeft - continuityBefore.scrollLeft) <= 1),
    "one or more painted frames changed horizontal scroll",
  );
  assert(
    continuityAfter.samples.every((sample) => Math.abs(sample.documentHeight - continuityBefore.documentHeight) <= 2),
    "one or more painted frames collapsed document height",
  );
  assert(Math.abs(continuityAfter.scrollTop - continuityBefore.scrollTop) <= 1, "dirty navigation did not retain final vertical scroll");
  assert(Math.abs(continuityAfter.scrollLeft - continuityBefore.scrollLeft) <= 1, "dirty navigation did not retain final horizontal scroll");
  assert(Math.abs(continuityAfter.documentHeight - continuityBefore.documentHeight) <= 2, "dirty navigation did not retain final document height");
  assert(continuityAfter.selectedXid === dirtyBXid, `last clicked target ${dirtyBXid} was not selected`);
  assert(await dirtyBRow.getByLabel("Description").inputValue() === "Navigation fixture 11", "target row did not show canonical data");
  assert(transactionMutationRequests === dirtyMutationBaseline + 1, "dirty row navigation completed with duplicate saves");
  assert(ledgerPageRequests === dirtyPageBaseline + 1, "dirty row navigation completed with duplicate page reloads");
  await page.unroute("**/rpc/replace_transaction", stallReplace);
  await page.unroute("**/rpc/ledger_page", stallLedger);
  await page.setViewportSize({ width: 1440, height: 900 });

  // Move to the always-visible blank transaction. It creates a simple transfer
  // on Enter, with PostgreSQL supplying the reciprocal posting.
  const appendFooter = ledgerRegister.locator("tfoot");
  const appendLauncher = appendFooter.locator("tr.append-launcher");
  await appendLauncher.click();
  let appendRow = appendFooter.locator("tr.append-row:not(.append-launcher)");
  await appendRow.getByLabel("New transaction date").waitFor();
  assert(await appendRow.count() === 1, "ledger footer has no single append row");
  assert(await appendFooter.locator("button").count() === 0, "new transaction footer exposes action buttons");
  assert(await appendRow.getByLabel("Transfer").locator('option[value=""]').count() === 1, "new transfer has no Select account default");
  await appendRow.getByLabel("New transaction date").fill("2026-02-10");
  await appendRow.getByLabel("New transaction description").fill("Browser created");
  await appendRow.getByLabel("Transfer").selectOption("Food");
  assert(await appendRow.getByLabel("Transfer").locator('option[value=""]').count() === 0, "assigned new transfer can be reset to Select account");
  await appendRow.getByLabel("New transaction withdrawal").fill("7");
  const createResponsePromise = waitForRpc("create_transaction");
  await appendRow.getByLabel("New transaction withdrawal").press("Enter");
  const createResponse = await createResponsePromise;
  assert(createResponse.ok(), `simple footer transaction returned HTTP ${createResponse.status()}`);
  const createRequest = createResponse.request().postDataJSON();
  assert(createRequest.p_book_id === "web-test", "footer transaction targeted the wrong book");
  assert(createRequest.p_transaction.simple.account === "Current Account", "footer lost its selected ledger account");
  assert(createRequest.p_transaction.simple.transfer_account === "Food", "footer lost its transfer account");
  assert(createRequest.p_transaction.simple.amount === "-7", "footer lost its withdrawal intent");
  assert(!("lines" in createRequest.p_transaction), "footer performed client-side counterline accounting");
  await displayedLedgerRow("Browser created").waitFor();
  appendRow = appendFooter.locator("tr.append-row:not(.append-launcher)");
  await appendRow.getByLabel("New transaction date").waitFor();
  assert(await appendRow.getByLabel("New transaction description").inputValue() === "", "footer did not reset after saving");
  assert(await appendRow.getByLabel("Transfer").locator('option[value=""]').count() === 1, "reset footer did not restore Select account");

  // Choosing the Transfer sentinel expands the footer in place. PostgreSQL
  // supplies the signed reciprocal amount shown in its permanent blank row;
  // choosing an account promotes that suggestion and exposes the next blank.
  await appendRow.getByLabel("New transaction date").fill("2026-02-11");
  await appendRow.getByLabel("New transaction description").fill("Browser split created");
  await appendRow.getByLabel("New transaction withdrawal").fill("7");
  await appendRow.getByLabel("Transfer").selectOption("__split_transaction__");
  let appendPostingRows = appendFooter.locator('tr.ledger-split-line[data-draft="line"]');
  let appendBlankRows = appendFooter.locator('tr.ledger-split-line[data-draft="blank"]');
  await appendBlankRows.getByLabel("Blank split account").waitFor();
  assert(await appendBlankRows.getByLabel("Blank split account").locator('option[value=""]').count() === 1, "blank split has no Select account default");
  assert(await appendPostingRows.count() === 1, "split footer did not expose the current-account posting");
  assert(await appendBlankRows.count() === 1, "split footer did not start with one permanent blank row");
  await waitForAttribute(appendBlankRows.getByLabel("Blank split deposit"), "placeholder", "7.00000");
  assert(await appendBlankRows.getByLabel("Blank split deposit").inputValue() === "", "SQL suggestion became a posting before an account was chosen");
  assert(await appendBlankRows.getAttribute("data-suggested-asset") === "GBP", "blank split did not identify the suggested asset");
  assert(await appendBlankRows.getAttribute("class").then((value) => value.includes("ledger-balancing-split")), "blank split suggestion lost its balancing style");

  // The reciprocal belongs to a specific asset. Choosing a foreign-asset
  // account must not copy a GBP amount into it. Once assigned, that posting can
  // switch accounts but cannot return to the empty Select account state.
  await appendBlankRows.getByLabel("Blank split account").selectOption("EUR Wallet");
  const foreignPosting = appendFooter.locator('tr.ledger-split-line[data-account="EUR Wallet"]');
  await foreignPosting.getByLabel("Deposit").waitFor();
  assert(await foreignPosting.getByLabel("Deposit").inputValue() === "", "GBP suggestion leaked into a EUR posting");
  assert(await foreignPosting.getByLabel("Account").locator('option[value=""]').count() === 0, "assigned split can be reset to Select account");
  await waitForAttribute(appendBlankRows.getByLabel("Blank split deposit"), "placeholder", "7.00000");
  assert(await appendBlankRows.getByLabel("Blank split account").locator('option[value=""]').count() === 1, "replacement blank split lost Select account");

  await appendBlankRows.getByLabel("Blank split account").selectOption("Food");
  const foodPosting = appendFooter.locator('tr.ledger-split-line[data-account="Food"]');
  await waitForInputValue(foodPosting.getByLabel("Deposit"), "7.00000");
  await waitForAttribute(appendBlankRows.getByLabel("Blank split deposit"), "placeholder", "");
  assert(await foodPosting.getByLabel("Deposit").inputValue() === "7.00000", "selecting Food did not promote the SQL suggestion");
  assert(await appendBlankRows.getByLabel("Blank split deposit").getAttribute("placeholder") === "", "balanced draft retained a reciprocal suggestion");
  assert(await appendPostingRows.count() === 3 && await appendBlankRows.count() === 1, "editing the blank row did not materialize Food and replace the blank");

  // Partially entered rows remain visible, but are presentation state until
  // they have both an account and a non-zero amount.
  await appendBlankRows.getByLabel("Blank split memo").fill("Unfinished split note");
  const memoOnlyPosting = appendFooter.locator('tr.ledger-split-line[data-draft="line"][data-account=""]');
  await memoOnlyPosting.getByLabel("Memo").waitFor();
  assert(await memoOnlyPosting.getByLabel("Memo").inputValue() === "Unfinished split note", "memo-only split was not retained inline");
  await appendBlankRows.getByLabel("Blank split account").selectOption("Fees");
  const feePosting = appendFooter.locator('tr.ledger-split-line[data-account="Fees"]');
  await feePosting.getByLabel("Deposit").waitFor();
  assert(await feePosting.getByLabel("Deposit").inputValue() === "", "balanced draft promoted a nonexistent suggestion");
  assert(await appendBlankRows.count() === 1, "materializing an incomplete row did not replace the permanent blank");
  assert(await appendFooter.locator("button").count() === 0, "split footer exposes Add split or transaction action buttons");

  // Return draft-balance responses out of order. The request for Food=5 is
  // held while Food=6 completes; its later +2 result must not overwrite +1.
  holdFoodFiveBalance = true;
  await foodPosting.getByLabel("Deposit").fill("5");
  await foodPosting.getByLabel("Deposit").blur();
  await foodFiveHeld;
  await foodPosting.getByLabel("Deposit").fill("6");
  await foodPosting.getByLabel("Deposit").blur();
  await waitForAttribute(appendBlankRows.getByLabel("Blank split deposit"), "placeholder", "1.00000");
  const foodSixBalanceRequest = [...draftBalanceRequests].reverse().find((body) =>
    body.p_lines.some((line) => line.account === "Food" && line.amount === "6")
  );
  assert(foodSixBalanceRequest !== undefined, "Food override did not request a new SQL draft balance");
  assert(
    JSON.stringify(foodSixBalanceRequest.p_lines.map((line) => line.account)) === JSON.stringify(["Current Account", "Food"]),
    `draft balance included incomplete rows: ${JSON.stringify(foodSixBalanceRequest.p_lines)}`,
  );
  await heldFoodFiveRoute.fulfill({
    status: 200,
    contentType: "application/json",
    body: '[{"asset":"GBP","amount":2.00000}]',
  }).catch(() => {});
  await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  assert(await appendBlankRows.getByLabel("Blank split deposit").getAttribute("placeholder") === "1.00000", "stale SQL balance overwrote the latest reciprocal");

  // Account-only and zero-valued drafts are omitted from writes. The complete
  // Current Account/Food postings remain explicitly unbalanced and SQL rejects
  // them without misclassifying the partial rows as INVALID_LINE.
  const missingAmountResponsePromise = waitForRpc("create_transaction");
  await feePosting.getByLabel("Account").press("Enter");
  const missingAmountResponse = await missingAmountResponsePromise;
  assert(missingAmountResponse.status() === 400, "account-only draft did not leave the complete transaction unbalanced");
  const missingAmountRequest = missingAmountResponse.request().postDataJSON();
  assert(missingAmountRequest.p_transaction.lines.length === 2, "account-only or memo-only draft leaked into the mutation payload");
  assert(
    JSON.stringify(missingAmountRequest.p_transaction.lines.map((line) => line.account)) === JSON.stringify(["Current Account", "Food"]),
    `account-only mutation payload is ${JSON.stringify(missingAmountRequest.p_transaction.lines)}`,
  );
  await page.locator(".status-line").getByText(/TRANSACTION_NOT_BALANCED/).waitFor();
  assert(await feePosting.getByLabel("Deposit").inputValue() === "", "failed save discarded the account-only draft");

  // Number-input strings can be outside JavaScript Float's finite range. They
  // must still reach PostgreSQL verbatim so SQL, not the display layer,
  // decides whether the configured NUMERIC domain accepts them.
  const oversizedAmount = "1e400";
  const oversizedBalancePromise = page.waitForResponse((response) => {
    const url = new URL(response.url());
    return url.pathname.endsWith("/rpc/transaction_draft_balance_text")
      && response.request().postData()?.includes(`\"amount\":\"${oversizedAmount}\"`);
  });
  await feePosting.getByLabel("Deposit").fill(oversizedAmount);
  assert(await feePosting.getByLabel("Deposit").inputValue() === oversizedAmount, "oversized exact decimal disappeared from its input");
  await feePosting.getByLabel("Deposit").blur();
  await oversizedBalancePromise;
  const oversizedSaveResponsePromise = waitForRpc("create_transaction");
  await feePosting.getByLabel("Deposit").press("Enter");
  const oversizedSaveResponse = await oversizedSaveResponsePromise;
  const oversizedSaveRequest = oversizedSaveResponse.request().postDataJSON();
  assert(
    oversizedSaveRequest.p_transaction.lines.some((line) => line.account === "Fees" && line.amount === oversizedAmount),
    "oversized exact decimal was omitted before PostgreSQL validation",
  );

  await feePosting.getByLabel("Deposit").fill("0");
  const zeroAmountResponsePromise = waitForRpc("create_transaction");
  await feePosting.getByLabel("Deposit").press("Enter");
  const zeroAmountResponse = await zeroAmountResponsePromise;
  assert(zeroAmountResponse.status() === 400, "zero-valued draft did not leave the complete transaction unbalanced");
  const zeroAmountRequest = zeroAmountResponse.request().postDataJSON();
  assert(zeroAmountRequest.p_transaction.lines.length === 2, "zero-valued draft leaked into the mutation payload");
  assert(
    JSON.stringify(zeroAmountRequest.p_transaction.lines.map((line) => line.account)) === JSON.stringify(["Current Account", "Food"]),
    `zero-valued mutation payload is ${JSON.stringify(zeroAmountRequest.p_transaction.lines)}`,
  );
  await page.locator(".status-line").getByText(/TRANSACTION_NOT_BALANCED/).waitFor();
  assert(await feePosting.getByLabel("Account").inputValue() === "Fees", "failed save discarded the zero-valued draft account");
  assert(await feePosting.getByLabel("Deposit").inputValue() === "", "zero-valued draft was rendered as a real posting");

  // A non-zero override is a real posting. Its remaining reciprocal appears in
  // the new blank row, and Enter preserves the explicit SQL balance failure.
  await feePosting.getByLabel("Deposit").fill("0.5");
  await feePosting.getByLabel("Deposit").blur();
  await waitForAttribute(appendBlankRows.getByLabel("Blank split deposit"), "placeholder", "0.50000");
  const invalidSaveResponsePromise = waitForRpc("create_transaction");
  await feePosting.getByLabel("Deposit").press("Enter");
  const invalidSaveResponse = await invalidSaveResponsePromise;
  assert(invalidSaveResponse.status() === 400, `invalid split save returned HTTP ${invalidSaveResponse.status()} instead of 400`);
  const invalidSaveRequest = invalidSaveResponse.request().postDataJSON();
  assert("lines" in invalidSaveRequest.p_transaction, "split footer did not send explicit posting intent to PostgreSQL");
  assert(!("simple" in invalidSaveRequest.p_transaction), "split footer was encoded as a simple transaction");
  assert(invalidSaveRequest.p_transaction.lines.length === 3, "permanent blank split leaked into the SQL payload");
  const invalidLines = Object.fromEntries(invalidSaveRequest.p_transaction.lines.map((line) => [line.account, line.amount]));
  assert(
    JSON.stringify(invalidLines) === JSON.stringify({ "Current Account": "-7", Food: "6", Fees: "0.5" }),
    `split SQL intent is ${JSON.stringify(invalidLines)}`,
  );
  await page.locator(".status-line").getByText(/TRANSACTION_NOT_BALANCED/).waitFor();
  assert(await appendRow.getByLabel("New transaction description").inputValue() === "Browser split created", "failed save discarded the footer draft");
  assert(await appendPostingRows.count() === 5 && await appendBlankRows.count() === 1, "failed save discarded split lines or their permanent blank");
  assert(await feePosting.getByLabel("Deposit").inputValue() === "0.5", "failed save discarded the invalid field value");
  assert(await memoOnlyPosting.getByLabel("Memo").inputValue() === "Unfinished split note", "failed save discarded an incomplete split draft");
  assert(!(await feePosting.getByLabel("Deposit").isDisabled()), "failed save left the split draft locked");
  assert(await displayedLedgerRow("Browser split created").count() === 0, "invalid split transaction was written");

  await feePosting.getByLabel("Deposit").fill("1");
  await feePosting.getByLabel("Deposit").blur();
  await waitForAttribute(appendBlankRows.getByLabel("Blank split deposit"), "placeholder", "");
  assert(await appendBlankRows.getByLabel("Blank split deposit").getAttribute("placeholder") === "", "balanced correction did not clear the reciprocal suggestion");
  const splitCreateResponsePromise = waitForRpc("create_transaction");
  await feePosting.getByLabel("Deposit").press("Enter");
  const splitCreateResponse = await splitCreateResponsePromise;
  assert(splitCreateResponse.ok(), `corrected split save returned HTTP ${splitCreateResponse.status()}`);
  await displayedLedgerRow("Browser split created").waitFor();
  assert(await appendFooter.locator('tr.ledger-split-line').count() === 0, "Enter did not fold the saved split transaction");
  assert(previewRpcRequests === 0, "register editing called the removed preview RPC");

  await page.screenshot({
    path: `${screenshotDirectory}/njord-desktop.png`,
    fullPage: true,
  });

  // Journal is a primary workspace, not an item hidden in the report library.
  await primaryDestination("Journal").click();
  await waitUntilReady();
  const journalPanel = panel("General Journal");
  await journalPanel.getByRole("heading", { name: "General Journal", exact: true }).waitFor();
  await assertActiveWorkspace("Journal");
  await journalPanel.locator("tbody tr").first().waitFor();
  assert(await topbar.getByLabel("Account", { exact: true }).count() === 0, "Journal exposes an irrelevant topbar account selector");
  const journalHeaders = await journalPanel.locator("thead th").allTextContents();
  assert(
    JSON.stringify(journalHeaders) === JSON.stringify(["Date", "Description", "R", "Account", "Memo", "Debit", "Credit"]),
    `General Journal columns are ${journalHeaders.join(", ")}`,
  );
  assert(await journalPanel.getByText("XID", { exact: true }).count() === 0, "General Journal exposes internal transaction identifiers");
  assert(await journalPanel.locator('input[type="checkbox"]').count() === 0, "General Journal exposes reconciliation controls");
  assert(
    await journalPanel.getByText("9007199254740993.00001", { exact: true }).count() > 0,
    "General Journal rounded a high-precision posting",
  );
  const journalAppearance = await journalPanel.locator(".general-journal-table").evaluate((table) => {
    const firstLine = table.querySelector("tbody .journal-first-line");
    const credit = table.querySelector("tbody .journal-credit-account");
    const even = table.querySelector("tbody .journal-group-even td");
    const odd = table.querySelector("tbody .journal-group-odd td");
    if (!firstLine || !credit || !even || !odd) return null;
    return {
      firstLineBorder: getComputedStyle(firstLine.children[0]).borderTopWidth,
      creditIndent: Number.parseFloat(getComputedStyle(credit).paddingLeft),
      evenBackground: getComputedStyle(even).backgroundColor,
      oddBackground: getComputedStyle(odd).backgroundColor,
    };
  });
  assert(journalAppearance !== null, "general journal is missing its transaction grouping classes");
  assert(journalAppearance.firstLineBorder === "2px", "general journal transaction boundary is missing");
  assert(journalAppearance.creditIndent >= 28, "general journal credits lost their indentation");
  assert(journalAppearance.evenBackground === "rgb(191, 222, 185)", "general journal green band is missing");
  assert(journalAppearance.oddBackground === "rgb(255, 239, 152)", "general journal yellow band is missing");

  // Reconciliation is posting-level and belongs inside the Accounts
  // workflow. Its mutation uses the internal posting identity without
  // displaying a transaction identifier.
  await primaryDestination("Accounts").click();
  await waitUntilReady();
  const reconciliationResponsePromise = waitForRpc("reconciliation_page");
  await panel("Accounts").getByRole("link", { name: "Reconcile", exact: true }).click();
  const reconciliationResponse = await reconciliationResponsePromise;
  assert(reconciliationResponse.ok(), `Reconciliation returned HTTP ${reconciliationResponse.status()}`);
  await waitUntilReady();
  const reconciliationPanel = panel("Reconciliation");
  await reconciliationPanel.getByRole("heading", { name: "Reconciliation", exact: true }).waitFor();
  await assertActiveWorkspace("Accounts");
  assert(await primaryDestination("Reconciliation").count() === 0, "Reconciliation remains a top-level tab");
  const reconciliationHeaders = await reconciliationPanel.locator("thead th").allTextContents();
  assert(
    JSON.stringify(reconciliationHeaders) === JSON.stringify(["Date", "Description", "Account", "Asset", "Deposit", "Withdrawal", "Reconciled"]),
    `Reconciliation columns are ${reconciliationHeaders.join(", ")}`,
  );
  assert(await reconciliationPanel.getByText("XID", { exact: true }).count() === 0, "Reconciliation exposes internal transaction identifiers");
  assert(await topbar.getByLabel("Account", { exact: true }).count() === 0, "Reconciliation moved its Account filter into the topbar");

  const replacementReconciliationRow = reconciliationPanel
    .locator('tbody tr.reconciliation-row[data-account="Current Account"]')
    .filter({ has: page.getByText("Browser replacement", { exact: true }) })
    .first();
  await replacementReconciliationRow.waitFor();
  const postingXid = await replacementReconciliationRow.getAttribute("data-xid");
  assert(postingXid !== null, "Reconciliation row has no internal posting identity");
  const reconciliationCheckbox = replacementReconciliationRow.getByRole("checkbox");
  assert(!(await reconciliationCheckbox.isChecked()), "new posting did not start unreconciled");
  const reconcileMutationPromise = waitForRpc("set_posting_reconciled");
  await reconciliationCheckbox.check();
  const reconcileMutation = await reconcileMutationPromise;
  assert(reconcileMutation.ok(), `posting reconciliation returned HTTP ${reconcileMutation.status()}`);
  const reconcileIntent = reconcileMutation.request().postDataJSON();
  assert(reconcileIntent.p_book_id === "web-test", "posting reconciliation targeted the wrong book");
  assert(String(reconcileIntent.p_xid) === postingXid, "posting reconciliation targeted the wrong transaction internally");
  assert(reconcileIntent.p_account_id === "Current Account", "posting reconciliation targeted the wrong account");
  assert(reconcileIntent.p_reconciled === true, "posting reconciliation sent the wrong state");
  await page.getByText("Posting reconciled", { exact: true }).waitFor();
  assert(await reconciliationCheckbox.isChecked(), "reconciled posting did not update in place");

  const reopenMutationPromise = waitForRpc("set_posting_reconciled");
  await reconciliationCheckbox.uncheck();
  const reopenMutation = await reopenMutationPromise;
  assert(reopenMutation.ok(), `posting reopen returned HTTP ${reopenMutation.status()}`);
  await page.getByText("Posting reopened", { exact: true }).waitFor();
  assert(!(await reconciliationCheckbox.isChecked()), "reopened posting did not update in place");

  const filteredReconciliationPromise = waitForRpc("reconciliation_page");
  await reconciliationPanel.getByLabel("Account filter").selectOption("Food");
  const filteredReconciliation = await filteredReconciliationPromise;
  assert(filteredReconciliation.ok(), `account-filtered reconciliation returned HTTP ${filteredReconciliation.status()}`);
  await waitUntilReady();
  assert(
    await reconciliationPanel.locator('tbody tr.reconciliation-row:not([data-account="Food"])').count() === 0,
    "Reconciliation Account filter returned postings from another account",
  );
  const preciseReconciliationPromise = waitForRpc("reconciliation_page");
  await reconciliationPanel.getByLabel("Account filter").selectOption("Current Account");
  const preciseReconciliationResponse = await preciseReconciliationPromise;
  assert(preciseReconciliationResponse.ok(), `precision reconciliation returned HTTP ${preciseReconciliationResponse.status()}`);
  await waitUntilReady();
  assert(
    await reconciliationPanel.getByText("9007199254740993.00001", { exact: true }).count() > 0,
    "Reconciliation rounded a high-precision posting",
  );

  // Reports first opens the library. Each choice then opens one financial
  // report through one canonical, SQL-defined page RPC.
  const reportChoices = ["Balance Sheet", "Net Worth", "Trial Balance", "Profit & Loss", "Cash Flow"];
  await primaryDestination("Reports").click();
  await waitUntilReady();
  let reportLibrary = panel("Reports");
  await reportLibrary.getByRole("heading", { name: "Reports", exact: true }).waitFor();
  await assertActiveWorkspace("Reports");
  const reportCards = reportLibrary.locator("a.report-card");
  assert(await reportCards.count() === reportChoices.length, `report library has ${await reportCards.count()} cards instead of ${reportChoices.length}`);
  for (const choice of reportChoices) {
    const card = reportCard(reportLibrary, choice);
    assert(await card.count() === 1, `${choice} is not one full-card report link`);
    const href = await card.getAttribute("href");
    const target = new URL(href, base);
    assert(
      target.searchParams.get("page") === "report"
        && target.searchParams.get("book") === "web-test"
        && target.searchParams.get("report") !== null,
      `${choice} has noncanonical href ${href}`,
    );
  }
  assert(
    await reportLibrary.locator("a.report-card").filter({ hasText: "General Journal" }).count() === 0,
    "Journal remains duplicated in the report library",
  );

  const balanceCard = reportCard(reportLibrary, "Balance Sheet");
  assert(await balanceCard.locator("p").count() > 0, "Balance Sheet card has no linked description area");
  const balancePopup = await openByMiddleClick(balanceCard);
  try {
    await panelOn(balancePopup, "Balance Sheet").getByRole("heading", { name: "Balance Sheet", exact: true }).waitFor();
    await assertActiveWorkspaceOn(balancePopup, "Reports");
    assert((await topbarOn(balancePopup).locator(".active-book-context").textContent()).includes("Web Test"), "middle-clicked report lost its active Book");
    const balancePopupUrl = new URL(balancePopup.url());
    assert(balancePopupUrl.searchParams.get("page") === "report", "middle-clicked report did not use the generic report route");
    assert(balancePopupUrl.searchParams.get("report") === "balance-sheet", "middle-clicked report opened the wrong report");
  } finally {
    await balancePopup.close();
  }
  await reportLibrary.getByRole("heading", { name: "Reports", exact: true }).waitFor();

  const reportPages = [
    ["Balance Sheet", "Balance Sheet", "balance-sheet"],
    ["Net Worth", "Net Worth", "net-worth"],
    ["Trial Balance", "Trial Balance", "trial-balance"],
    ["Profit & Loss", "Profit & Loss", "profit-loss"],
    ["Cash Flow", "Cash Flow", "cash-flow"],
  ];
  for (const [choice, heading, reportId] of reportPages) {
    reportLibrary = panel("Reports");
    const reportResponsePromise = waitForRpc("report_page");
    const card = reportCard(reportLibrary, choice);
    if (reportId === "balance-sheet") {
      await card.locator("p").click();
    } else {
      await card.click();
    }
    const reportResponse = await reportResponsePromise;
    assert(reportResponse.ok(), `${heading} returned HTTP ${reportResponse.status()}`);
    assert(
      reportResponse.request().postDataJSON().p_report_id === reportId,
      `${heading} requested the wrong SQL report definition`,
    );
    assert(
      new URL(page.url()).search === `?page=report&book=web-test&report=${reportId}`,
      `${heading} navigation produced noncanonical URL ${page.url()}`,
    );
    const reportComponents = await reportResponse.json();
    const reportContext = reportComponents.find(
      (component) => component.component === "page_context"
        && component.payload.page === "report"
        && component.payload.report_id === reportId,
    )?.payload;
    assert(reportContext !== undefined, `${heading} response has no matching SQL page context`);
    const reportDefinition = reportComponents.find(
      (component) => component.component === "report_definition"
        && component.payload.report_id === reportId,
    )?.payload;
    assert(reportDefinition?.title === heading, `${heading} title is not database-defined`);
    assert(
      reportComponents.some((component) => component.component === "report_column"),
      `${heading} has no database-defined columns`,
    );
    await waitUntilReady();
    const reportPanel = panel(heading);
    await reportPanel.getByRole("heading", { name: heading, exact: true }).waitFor();
    await assertActiveWorkspace("Reports");
    await reportPanel.locator("tbody tr").first().waitFor();
    assert(await topbar.getByLabel("Account", { exact: true }).count() === 0, `${heading} exposes an irrelevant topbar account selector`);
    assert(await reportPanel.locator(".report-table").count() === 1, `${heading} lost its financial report table styling`);
    assert(await reportPanel.locator(".report-total").count() > 0, `${heading} has no visually distinct totals`);
    const sqlFormats = reportComponents
      .filter((component) => component.component === "report_column")
      .map((component) => component.payload.value_format);
    const renderedFormats = await reportPanel.locator("tbody tr:first-child td").evaluateAll(
      (cells) => cells.map((cell) => cell.dataset.valueFormat),
    );
    assert(
      JSON.stringify(renderedFormats) === JSON.stringify(sqlFormats),
      `${heading} ignored SQL value-format metadata (${renderedFormats.join(", ")})`,
    );
    if (reportId === "balance-sheet" || reportId === "net-worth" || reportId === "profit-loss") {
      const rootName = reportPanel.locator('tr.report-group-row[data-depth="0"] .report-account-name').first();
      const nestedName = reportPanel.locator('tr[data-depth]:not([data-depth="0"]) .report-account-name').first();
      const rootBox = await rootName.boundingBox();
      const nestedBox = await nestedName.boundingBox();
      assert(rootBox && nestedBox, `${heading} hierarchy has no rendered account positions`);
      assert(nestedBox.x - rootBox.x >= 32, `${heading} account indentation is only ${nestedBox.x - rootBox.x}px`);
    }
    if (reportId === "balance-sheet" || reportId === "net-worth" || reportId === "trial-balance") {
      const asOf = await reportPanel.getByLabel("As of").inputValue();
      assert(/^\d{4}-\d{2}-\d{2}$/.test(asOf), `${heading} did not use its SQL as-of default`);
    }
    if (reportId === "trial-balance") {
      const highMagnitudeExact = reportComponents
        .filter((component) => component.component === "generic_report_row")
        .flatMap((component) => component.payload.cells)
        .map((cell) => cell.exact)
        .find((exact) => typeof exact === "string" && exact.startsWith("9007199254741"));
      assert(
        highMagnitudeExact !== undefined
          && await reportPanel.getByText(highMagnitudeExact, { exact: true }).count() > 0,
        "generic report renderer lost a high-magnitude rounded SQL decimal",
      );
    }
    if (reportId === "net-worth") {
      const headers = await reportPanel.locator("thead th").allTextContents();
      assert(
        JSON.stringify(headers) === JSON.stringify([
          "Account",
          "Commodity",
          "Native balance",
          "Market value",
          "Valuation",
        ]),
        `Net Worth columns are ${headers.join(", ")}`,
      );
      assert(await reportPanel.getByText("Net Worth", { exact: true }).count() >= 2, "Net Worth has no grand total");
      assert(await reportPanel.getByRole("heading", { name: "Net Worth over time", exact: true }).count() === 1, "Net Worth has no history chart");
      assert(await reportPanel.locator(".report-bar").count() === 12, "Net Worth history does not contain twelve generic bars");
      assert(await reportPanel.locator('.report-bar-chart[data-value-format="money"]').count() === 1, "Net Worth chart ignored its SQL value format");
      assert(await reportPanel.locator(".report-chart-data li").count() === 12, "Net Worth chart has no accessible data series");
      assert(
        reportComponents.filter((component) => component.component === "bar_chart_definition").length === 1,
        "Net Worth chart is not database-defined",
      );
    }
    if (reportId === "profit-loss") {
      await reportPanel.getByLabel("From").fill("2026-12-31");
      await reportPanel.getByLabel("To").fill("2026-01-01");
      await reportPanel.getByRole("button", { name: "Refresh" }).click();
      const validationAlert = page.getByRole("alert");
      await validationAlert.getByText("The start date must not be after the end date.", { exact: true }).waitFor();
      assert(await validationAlert.getAttribute("aria-live") === "assertive", "report validation is not announced assertively");
    }
    if (reportId === "cash-flow") {
      const expectedFrom = reportContext.from ?? "";
      const expectedTo = reportContext.to ?? "";
      assert(await reportPanel.getByLabel("From").inputValue() === expectedFrom, "Cash Flow did not use its fresh SQL From default");
      assert(await reportPanel.getByLabel("To").inputValue() === expectedTo, "Cash Flow did not use its fresh SQL To default");
      assert(
        expectedFrom !== "2026-12-31" && expectedTo !== "2026-01-01",
        "Cash Flow inherited the invalid Profit & Loss range",
      );
    }
    if (reportId !== "cash-flow") {
      await primaryDestination("Reports").click();
      await waitUntilReady();
      reportLibrary = panel("Reports");
      await reportLibrary.getByRole("heading", { name: "Reports", exact: true }).waitFor();
    }
  }

  // Books leads to SQL-backed per-Book management details. The
  // permanent identifier, explicit entity type, effective-dated reporting
  // currency, ACL, and optional jurisdiction packs round-trip through SQL.
  await openBookAdmin("web-test");
  const bookWorkspace = page.locator(".book-workspace");
  await bookWorkspace.getByRole("heading", { name: "Book", exact: true }).waitFor();
  await assertActiveWorkspace("Books");
  assert(await topbar.getByRole("link", { name: "Accounts", exact: true }).count() === 1, "Book management hides Accounts");
  assert(await topbar.getByRole("link", { name: "Journal", exact: true }).count() === 1, "Book management hides Journal");
  assert(await topbar.getByRole("link", { name: "Reports", exact: true }).count() === 1, "Book management hides Reports");
  await bookWorkspace.getByText("web-test", { exact: true }).waitFor();
  await bookWorkspace.getByText("GBP", { exact: true }).first().waitFor();
  assert(await bookWorkspace.getByLabel("Identifier", { exact: true }).count() === 0, "Book identifier is editable");
  assert(await bookWorkspace.getByLabel("Currency").inputValue() === "GBP", "Book reporting currency did not load");
  assert(await bookWorkspace.getByLabel("Owner or entity").inputValue() === "household", "new book was not explicitly a household");
  assert(await bookWorkspace.locator(".configuration-status").textContent() === "Household or individual", "household was labelled as jurisdiction-ready");
  const bookName = bookWorkspace.getByLabel("Book name");
  assert(await bookName.inputValue() === "Web Test", "Book settings did not load the canonical display name");
  await bookName.fill("Web Test renamed");
  await bookWorkspace.getByRole("button", { name: "Save book details" }).click();
  await page.getByText("Book details saved", { exact: true }).waitFor();
  assert(await bookWorkspace.getByLabel("Book name").inputValue() === "Web Test renamed", "Book name update did not round-trip through SQL");
  await bookWorkspace.getByLabel("Book name").fill("Web Test");
  await bookWorkspace.getByRole("button", { name: "Save book details" }).click();
  await page.getByText("Book details saved", { exact: true }).waitFor();

  await bookWorkspace.getByLabel("Owner or entity").selectOption("company");
  await bookWorkspace.getByRole("button", { name: "Save book details" }).click();
  await page.getByText("Book details saved", { exact: true }).waitFor();
  await bookWorkspace.getByText("Company", { exact: true }).first().waitFor();
  await bookWorkspace.getByLabel("Legal name").fill("Web Test Ltd");
  await bookWorkspace.getByLabel("Period identifier").fill("2026");
  await bookWorkspace.getByLabel("Period start").fill("2026-01-01");
  await bookWorkspace.getByLabel("Period end").fill("2026-12-31");
  assert(await bookWorkspace.getByLabel("VAT scheme").inputValue() === "not_registered", "company form ignored the database VAT default");
  assert(await bookWorkspace.getByLabel("VAT control account").isDisabled(), "non-VAT company asks for a VAT control account");
  await bookWorkspace.getByRole("button", { name: "Save UK company settings" }).click();
  await page.getByText("UK company settings saved", { exact: true }).waitFor();
  await bookWorkspace.getByText("UK setup complete", { exact: true }).waitFor();
  assert(await bookWorkspace.locator(".configuration-check-complete").count() === 4, "atomic company setup did not complete all configuration checks");
  assert(!(await bookWorkspace.getByLabel("Period identifier").isEditable()), "existing accounting-period identifier remains editable");

  // A profiled UK company receives additional report groups from SQL. The
  // same generic report route and renderer handle them without application
  // tabs or report-specific Elm pages.
  await selectBook("uk-business");
  await primaryDestination("Reports").click();
  await waitUntilReady();
  const ukReportLibrary = panel("Reports");
  await ukReportLibrary.getByRole("heading", { name: "Reports", exact: true }).waitFor();
  assert(await ukReportLibrary.locator("a.report-card").count() === 16, "UK report library does not contain all 16 database-defined reports");
  const ukReportGroups = await ukReportLibrary.locator(".report-group-heading").allTextContents();
  assert(
    JSON.stringify(ukReportGroups) === JSON.stringify([
      "Financial statements",
      "UK statutory accounts",
      "HMRC",
      "Supporting schedules",
    ]),
    `UK report groups are ${ukReportGroups.join(" -> ")}`,
  );

  await reportCard(ukReportLibrary, "VAT Return Working Paper").click();
  await waitUntilReady();
  const vatReportPanel = panel("VAT Return Working Paper");
  await vatReportPanel.getByRole("heading", { name: "VAT Return Working Paper", exact: true }).waitFor();
  assert(await vatReportPanel.getByLabel("From").inputValue() === "2026-01-01", "VAT working paper ignored the configured period start");
  assert(await vatReportPanel.getByLabel("To").inputValue() === "2026-12-31", "VAT working paper ignored the configured period end");
  assert(await vatReportPanel.locator("tbody tr").count() === 12, "VAT working paper does not render nine boxes plus its control reconciliation");
  await vatReportPanel.getByText("3060.00", { exact: true }).first().waitFor();
  await vatReportPanel.getByText("2092.00", { exact: true }).first().waitFor();

  await primaryDestination("Reports").click();
  await waitUntilReady();
  const ukReportLibraryAgain = panel("Reports");
  await reportCard(ukReportLibraryAgain, "Aged Debtors").click();
  await waitUntilReady();
  const agedDebtorsPanel = panel("Aged Debtors");
  await agedDebtorsPanel.getByRole("heading", { name: "Aged Debtors", exact: true }).waitFor();
  assert(await agedDebtorsPanel.locator("tbody tr").count() === 2, "Aged Debtors does not show both open invoices");
  await agedDebtorsPanel.getByText("Alpha Design Co", { exact: true }).waitFor();
  await agedDebtorsPanel.getByText("Beta Retail Ltd", { exact: true }).waitFor();

  // A TWD book gets its Taiwan setup surface and its injection-moulding
  // report library from SQL. The same generic renderer handles production
  // costing without adding report knowledge to Elm.
  await selectBook("taiwan-injection");
  await openBookAdmin("taiwan-injection");
  const taiwanBookWorkspace = page.locator(".book-workspace");
  await taiwanBookWorkspace.getByRole("heading", { name: "Taiwan business", exact: true }).waitFor();
  await taiwanBookWorkspace.getByText("Taiwan manufacturing", { exact: true }).waitFor();
  assert(
    await taiwanBookWorkspace.getByLabel("Unified Business Number").inputValue() === "54321678",
    "Taiwan Book form did not hydrate its SQL-owned business profile",
  );
  assert(
    await taiwanBookWorkspace.getByLabel("Enable injection-moulding manufacturing records").isChecked(),
    "Taiwan Book form did not expose its manufacturing profile",
  );
  assert(
    !(await taiwanBookWorkspace.getByLabel("Enable injection-moulding manufacturing records").isDisabled()),
    "enabled manufacturing extension cannot be turned off",
  );
  assert(
    await taiwanBookWorkspace.getByRole("button", { name: "Save UK company settings" }).count() === 0,
    "Taiwan Book form exposes UK configuration",
  );

  await selectBook("taiwan-injection");
  const taiwanAccounts = panel("Accounts");
  await taiwanAccounts.getByText("營運銀行存款", { exact: true }).waitFor();
  await taiwanAccounts.getByText("感測器外殼製成品", { exact: true }).waitFor();

  await primaryDestination("Reports").click();
  await waitUntilReady();
  const taiwanReportLibrary = panel("Reports");
  await taiwanReportLibrary.getByRole("heading", { name: "Reports", exact: true }).waitFor();
  const taiwanReportCardCount = await taiwanReportLibrary.locator("a.report-card").count();
  assert(
    taiwanReportCardCount === 17,
    `Taiwan report library contains ${taiwanReportCardCount} cards instead of five core and twelve pack reports`,
  );
  await reportCard(taiwanReportLibrary, "生產成本及單位成本表").click();
  await waitUntilReady();
  const productionCostPanel = panel("生產成本及單位成本表");
  await productionCostPanel.getByRole("heading", { name: "生產成本及單位成本表", exact: true }).waitFor();
  await productionCostPanel.getByRole("columnheader", { name: "直接材料", exact: true }).waitFor();
  await productionCostPanel.getByText("ABS 感測器外殼", { exact: true }).waitFor();
  assert(
    await productionCostPanel.locator("tbody tr").count() === 2,
    "Taiwan production-cost report did not render both demo production runs",
  );

  // Add-book and add-account pages consume defaults and choices from their
  // page_context rows, then their mutations return to the new ledger.
  await primaryDestination("Books").click();
  await waitUntilReady();
  await panel("Books").getByRole("link", { name: "Add book…", exact: true }).click();
  await waitUntilReady();
  const addBook = panel("Add book");
  await addBook.getByRole("heading", { name: "Add book" }).waitFor();
  const addBookAsset = await addBook.getByLabel("Reporting asset").inputValue();
  assert(addBookAsset === "GBP", `add-book SQL default was not applied (received ${addBookAsset})`);
  await addBook.getByLabel("Identifier").fill("browser-book");
  await addBook.getByLabel("Name").fill("Browser Book");
  await addBook.getByLabel("Reporting asset").selectOption("USD");
  await addBook.getByRole("button", { name: "Create book" }).click();
  const createdBookAccounts = panel("Accounts");
  await createdBookAccounts.getByRole("heading", { name: "Accounts", exact: true }).waitFor();
  assert((await topbar.locator(".active-book-context").textContent()).includes("Browser Book · USD"), "created Book context was not selected");

  const addAccountLink = createdBookAccounts.getByRole("link", { name: "Add account…", exact: true });
  assert(await addAccountLink.getAttribute("href") === "/?page=add-account&book=browser-book", "Accounts index has no canonical Add account link");
  await addAccountLink.click();
  await waitUntilReady();
  const addAccount = panel("Add account");
  await addAccount.getByRole("heading", { name: "Add account" }).waitFor();
  assert(await addAccount.getByLabel("Class").inputValue() === "A", "add-account SQL class default was not applied");
  const addAccountAsset = await addAccount.getByLabel("Commodity").inputValue();
  assert(addAccountAsset === "USD", `add-account SQL commodity default was not applied (received ${addAccountAsset})`);
  assert(await addAccount.getByLabel("Parent account").inputValue() === "Assets", "new asset account did not default beneath Assets");
  assert(await addAccount.getByLabel("Account kind").inputValue() === "posting", "add-account SQL kind default was not applied");
  assert(
    !(await addAccount.getByLabel("Placeholder (group only; no direct postings)").isChecked()),
    "posting-account form unexpectedly defaults to placeholder",
  );
  assert(/^\d{4}-\d{2}-\d{2}$/.test(await addAccount.getByLabel("Opening date").inputValue()), "add-account SQL date default was not applied");
  await addAccount.getByLabel("Name").fill("Browser Cash");
  await addAccount.getByLabel("Opening balance (optional)").fill("25");
  await addAccount.getByRole("button", { name: "Create account" }).click();
  await waitUntilReady();
  await panel("Account ledger").getByRole("heading", { name: "Account ledger", exact: true }).waitFor();
  await page.getByText("Opening balance", { exact: true }).waitFor();
  await ledgerAccount
    .locator('option[value="Browser Cash"]:checked')
    .waitFor({ state: "attached" });
  assert(await ledgerAccount.inputValue() === "Browser Cash", "created account was not selected");
  assert(await topbar.getByLabel("Account", { exact: true }).count() === 0, "created account restored the topbar account selector");

  await page.setViewportSize({ width: 390, height: 844 });
  await page.screenshot({
    path: `${screenshotDirectory}/njord-mobile.png`,
    fullPage: true,
  });

  const viewportOverflow = await page.evaluate(
    () => document.documentElement.scrollWidth > window.innerWidth,
  );
  if (viewportOverflow) errors.push("the mobile document overflows the viewport");
  const mobileRegister = page.locator(".ledger-register");
  const mobileHeaders = await mobileRegister.locator("thead th").allTextContents();
  assert(JSON.stringify(mobileHeaders) === JSON.stringify(expectedLedgerHeaders), "mobile ledger lost its six-column register");
  assert(
    await mobileRegister.getByRole("columnheader", { name: "Actions", exact: true }).count() === 0,
    "mobile ledger restored its Actions column",
  );
  assert(await mobileRegister.locator("tfoot tr.append-row").count() === 1, "mobile ledger lost its new-transaction footer");
  const mobileLedgerAppearance = await mobileRegister.evaluate((table) => ({
    tableScrollWidth: table.scrollWidth,
    panelClientWidth: table.parentElement.clientWidth,
    rowHeight: table.querySelector("tbody .ledger-line").getBoundingClientRect().height,
  }));
  assert(
    mobileLedgerAppearance.tableScrollWidth > mobileLedgerAppearance.panelClientWidth,
    "mobile ledger no longer preserves the full accounting register",
  );
  assert(mobileLedgerAppearance.rowHeight <= 34, `mobile ledger rows wrapped to ${mobileLedgerAppearance.rowHeight}px`);

  if (errors.length > 0) {
    throw new Error(`browser errors:\n${errors.join("\n")}`);
  }

  process.stdout.write("ok - all page and editing browser smoke tests passed\n");
} finally {
  await browser.close();
}
