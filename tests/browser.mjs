import { chromium } from "playwright";

const base = process.argv[2] || "http://127.0.0.1:8080";
const screenshotDirectory = process.env.PLUTUS_SCREENSHOT_DIR || "/tmp";
const browser = await chromium.launch({ headless: true });

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  const errors = [];
  page.on("console", (message) => {
    if (message.type() === "error" && !message.text().includes("status of 400")) {
      errors.push(message.text());
    }
  });
  page.on("pageerror", (error) => errors.push(error.message));

  const panel = (heading) =>
    page.locator("section.panel").filter({
      has: page.getByRole("heading", { name: heading }),
    }).first();
  const waitUntilReady = () => page.getByText("Ready", { exact: true }).waitFor();

  await page.goto(base, { waitUntil: "networkidle" });
  await waitUntilReady();
  assert(await page.getByLabel("Book").locator('option[value=""]').count() === 1, "book navigation has no empty-state option");

  // Shell and ledger page, including details and SQL-backed normalization.
  await page.getByLabel("Book").selectOption("web-test");
  await page.getByText("Line updated", { exact: true }).waitFor();
  const originalRow = page.locator("tr").filter({ hasText: "Line updated" });
  await originalRow.getByRole("button", { name: "Details" }).click();
  await page.getByRole("cell", { name: "Food", exact: true }).first().waitFor();
  await originalRow.getByRole("button", { name: "Transaction" }).click();
  const editTransaction = panel(/^Edit transaction /);
  await editTransaction.getByRole("heading", { name: /^Edit transaction / }).waitFor();
  await editTransaction.getByRole("button", { name: "Preview" }).click();
  await page.getByText("Valid transaction", { exact: true }).waitFor();
  await page.getByText(/^Normalized:/).waitFor();

  // Replace a transaction through the Elm editor.
  await editTransaction.getByLabel("Description").fill("Browser replacement");
  await editTransaction.getByRole("button", { name: "Save transaction" }).click();
  await page.getByText("Browser replacement", { exact: true }).waitFor();

  // Update a ledger line through its dedicated mutation.
  const replacementRow = page.locator("tr").filter({ hasText: "Browser replacement" });
  await replacementRow.getByRole("button", { name: "Line" }).click();
  const lineEditor = panel(/^Edit ledger line /);
  await lineEditor.getByLabel("Description").fill("Browser line edit");
  await lineEditor.getByRole("button", { name: "Save line" }).click();
  await page.getByText("Browser line edit", { exact: true }).waitFor();

  // Create a transaction. First prove a failed write displays the structured
  // PostgreSQL error, then correct it and save it.
  await page.getByRole("button", { name: "New transaction" }).click();
  const newTransaction = panel("New transaction");
  await newTransaction.getByLabel("Date").fill("2026-02-10");
  await newTransaction.getByLabel("Description").fill("Browser created");
  const draftRows = newTransaction.locator(".transaction-lines tbody tr");
  await draftRows.nth(0).locator("select").selectOption("Current Account");
  await draftRows.nth(0).locator("input").nth(0).fill("-7");
  await draftRows.nth(1).locator("select").selectOption("Food");
  await draftRows.nth(1).locator("input").nth(0).fill("6");
  await newTransaction.getByRole("button", { name: "Save transaction" }).click();
  await page.getByText(/TRANSACTION_NOT_BALANCED/).waitFor();
  await draftRows.nth(1).locator("input").nth(0).fill("7");
  await newTransaction.getByRole("button", { name: "Preview" }).click();
  await page.getByText("Valid transaction", { exact: true }).waitFor();
  await newTransaction.getByRole("button", { name: "Save transaction" }).click();
  await page.getByText("Browser created", { exact: true }).waitFor();

  await page.screenshot({
    path: `${screenshotDirectory}/plutus-desktop.png`,
    fullPage: true,
  });

  // Exercise every report page through its one canonical page RPC.
  const reportPages = [
    ["general-journal", "General Journal"],
    ["balance-sheet", "Balance Sheet"],
    ["trial-balance", "Trial Balance"],
    ["profit-loss", "Income and Expenses"],
    ["cash-flow", "Cash Flow"],
  ];
  for (const [value, heading] of reportPages) {
    await page.getByLabel("Report").selectOption(value);
    await waitUntilReady();
    const reportPanel = panel(heading);
    await reportPanel.getByRole("heading", { name: heading }).waitFor();
    await reportPanel.locator("tbody tr").first().waitFor();
    if (value === "balance-sheet" || value === "trial-balance") {
      const asOf = await reportPanel.getByLabel("As of").inputValue();
      assert(/^\d{4}-\d{2}-\d{2}$/.test(asOf), `${heading} did not use its SQL as-of default`);
    }
    if (value === "profit-loss") {
      await reportPanel.getByLabel("From").fill("2026-12-31");
      await reportPanel.getByLabel("To").fill("2026-01-01");
      await reportPanel.getByRole("button", { name: "Refresh" }).click();
      await page.getByText("The start date must not be after the end date.", { exact: true }).waitFor();
    }
  }

  // Add-book and add-account pages consume defaults and choices from their
  // page_context rows, then their mutations return to the new ledger.
  await page.getByLabel("Book").selectOption("__add_book__");
  await waitUntilReady();
  const addBook = panel("Add book");
  await addBook.getByRole("heading", { name: "Add book" }).waitFor();
  const addBookAsset = await addBook.getByLabel("Reporting asset").inputValue();
  assert(addBookAsset === "GBP", `add-book SQL default was not applied (received ${addBookAsset})`);
  await addBook.getByLabel("Identifier").fill("browser-book");
  await addBook.getByLabel("Name").fill("Browser Book");
  await addBook.getByLabel("Reporting asset").selectOption("USD");
  await addBook.getByRole("button", { name: "Create book" }).click();
  await page.getByRole("heading", { name: "Account ledger" }).waitFor();
  assert(await page.getByLabel("Book").inputValue() === "browser-book", "created book was not selected");

  await page.getByLabel("Account").selectOption("__add_account__");
  await waitUntilReady();
  const addAccount = panel("Add account");
  await addAccount.getByRole("heading", { name: "Add account" }).waitFor();
  assert(await addAccount.getByLabel("Type").inputValue() === "A", "add-account SQL type default was not applied");
  const addAccountAsset = await addAccount.getByLabel("Asset").inputValue();
  assert(addAccountAsset === "USD", `add-account SQL asset default was not applied (received ${addAccountAsset})`);
  assert(/^\d{4}-\d{2}-\d{2}$/.test(await addAccount.getByLabel("Opening date").inputValue()), "add-account SQL date default was not applied");
  await addAccount.getByLabel("Name").fill("Browser Cash");
  await addAccount.getByLabel("Opening balance (optional)").fill("25");
  await addAccount.getByRole("button", { name: "Create account" }).click();
  await page.getByText("Opening balance", { exact: true }).waitFor();
  assert(await page.getByLabel("Account").inputValue() === "Browser Cash", "created account was not selected");

  await page.setViewportSize({ width: 390, height: 844 });
  await page.screenshot({
    path: `${screenshotDirectory}/plutus-mobile.png`,
    fullPage: true,
  });

  const viewportOverflow = await page.evaluate(
    () => document.documentElement.scrollWidth > window.innerWidth,
  );
  if (viewportOverflow) errors.push("the mobile document overflows the viewport");

  if (errors.length > 0) {
    throw new Error(`browser errors:\n${errors.join("\n")}`);
  }

  process.stdout.write("ok - all page and editing browser smoke tests passed\n");
} finally {
  await browser.close();
}
