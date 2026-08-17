-- Rich Taiwan plastic-injection factory demo. All identifiers, amounts, and
-- deadlines are illustrative. Reports are bookkeeping working papers, not
-- official returns or legal/tax determinations.

INSERT INTO books (id, name, reporting_asset, entity_type)
VALUES ('taiwan-injection', '福爾摩沙精密塑膠有限公司', 'TWD', 'company');

INSERT INTO taiwan_business_profiles (
    book_id, legal_name, unified_business_number, legal_form,
    business_tax_frequency, uses_uniform_invoices,
    established_on, responsible_person, registered_address,
    tax_registration_notes, notes
) VALUES (
    'taiwan-injection', '福爾摩沙精密塑膠有限公司', '54321678',
    'limited_company', 'bimonthly', TRUE,
    '2024-06-18', '林家豪',
    '桃園市龜山區工業路 88 號',
    '示範用一般稅額計算營業人，使用統一發票。',
    '僅供開發示範；申報及勞動法令義務請洽臺灣專業顧問確認。'
);

INSERT INTO taiwan_fiscal_periods (
    book_id, id, period_start, period_end, status,
    annual_income_tax_due_on, provisional_income_tax_due_on,
    undistributed_earnings_due_on, notes
) VALUES (
    'taiwan-injection', '2026', '2026-01-01', '2026-12-31', 'open',
    '2027-05-31', '2026-09-30', '2027-05-31',
    '示範用曆年制會計期間；所列日期仍須覆核。'
);

INSERT INTO taiwan_business_tax_periods (
    book_id, id, period_start, period_end, due_on, status, filed_on,
    payment_reference
) VALUES
    ('taiwan-injection', '2026-01-02', '2026-01-01', '2026-02-28', '2026-03-15', 'filed', '2026-03-12', '401-2026-01-02'),
    ('taiwan-injection', '2026-03-04', '2026-03-01', '2026-04-30', '2026-05-15', 'filed', '2026-05-14', '401-2026-03-04'),
    ('taiwan-injection', '2026-05-06', '2026-05-01', '2026-06-30', '2026-07-15', 'filed', '2026-07-14', '401-2026-05-06'),
    ('taiwan-injection', '2026-07-08', '2026-07-01', '2026-08-31', '2026-09-15', 'prepared', NULL, NULL),
    ('taiwan-injection', '2026-09-10', '2026-09-01', '2026-10-31', '2026-11-15', 'open', NULL, NULL),
    ('taiwan-injection', '2026-11-12', '2026-11-01', '2026-12-31', '2027-01-15', 'open', NULL, NULL);

INSERT INTO accts (
    book_id, id, name, type, atype, parent_id, account_kind, placeholder
) VALUES
    ('taiwan-injection', 'Assets', '資產', 'A', 'TWD', NULL, 'root', TRUE),
    ('taiwan-injection', 'Liabilities', '負債', 'L', 'TWD', NULL, 'root', TRUE),
    ('taiwan-injection', 'Equity', '權益', 'Q', 'TWD', NULL, 'root', TRUE),
    ('taiwan-injection', 'Income', '收入', 'I', 'TWD', NULL, 'root', TRUE),
    ('taiwan-injection', 'Expenses', '費用', 'E', 'TWD', NULL, 'root', TRUE),

    ('taiwan-injection', 'Current Assets', '流動資產', 'A', 'TWD', 'Assets', 'group', TRUE),
    ('taiwan-injection', 'Operating Bank', '營運銀行存款', 'A', 'TWD', 'Current Assets', 'bank', FALSE),
    ('taiwan-injection', 'Trade Receivables', '應收帳款', 'A', 'TWD', 'Current Assets', 'posting', FALSE),
    ('taiwan-injection', 'Input Business Tax', '進項稅額', 'A', 'TWD', 'Current Assets', 'posting', FALSE),
    ('taiwan-injection', 'Inventory', '存貨', 'A', 'TWD', 'Current Assets', 'group', TRUE),
    ('taiwan-injection', 'ABS Resin Inventory', 'ABS 樹脂', 'A', 'TWD', 'Inventory', 'posting', FALSE),
    ('taiwan-injection', 'PP Resin Inventory', 'PP 樹脂', 'A', 'TWD', 'Inventory', 'posting', FALSE),
    ('taiwan-injection', 'Colour Masterbatch Inventory', '色母粒', 'A', 'TWD', 'Inventory', 'posting', FALSE),
    ('taiwan-injection', 'Packaging Inventory', '包裝材料', 'A', 'TWD', 'Inventory', 'posting', FALSE),
    ('taiwan-injection', 'Work in Progress', '在製品', 'A', 'TWD', 'Inventory', 'posting', FALSE),
    ('taiwan-injection', 'Enclosure Inventory', '感測器外殼製成品', 'A', 'TWD', 'Inventory', 'posting', FALSE),
    ('taiwan-injection', 'Gear Inventory', '精密齒輪製成品', 'A', 'TWD', 'Inventory', 'posting', FALSE),
    ('taiwan-injection', 'Recoverable Scrap', '可回收廢塑料', 'A', 'TWD', 'Inventory', 'posting', FALSE),
    ('taiwan-injection', 'Production Equipment', '生產設備', 'A', 'TWD', 'Assets', 'group', TRUE),
    ('taiwan-injection', 'IMM-180 Asset', 'IMM-180 射出成型機', 'A', 'TWD', 'Production Equipment', 'fixed_asset', FALSE),
    ('taiwan-injection', 'Enclosure Mould Asset', '感測器外殼模具', 'A', 'TWD', 'Production Equipment', 'fixed_asset', FALSE),
    ('taiwan-injection', 'Gear Mould Asset', '精密齒輪模具', 'A', 'TWD', 'Production Equipment', 'fixed_asset', FALSE),
    ('taiwan-injection', 'Equipment Accumulated Depreciation', '累計折舊', 'A', 'TWD', 'Production Equipment', 'fixed_asset', FALSE),

    ('taiwan-injection', 'Current Liabilities', '流動負債', 'L', 'TWD', 'Liabilities', 'group', TRUE),
    ('taiwan-injection', 'Trade Payables', '應付帳款', 'L', 'TWD', 'Current Liabilities', 'posting', FALSE),
    ('taiwan-injection', 'Output Business Tax', '銷項稅額', 'L', 'TWD', 'Current Liabilities', 'posting', FALSE),
    ('taiwan-injection', 'Withholding Tax Payable', '應付扣繳稅款', 'L', 'TWD', 'Current Liabilities', 'posting', FALSE),

    ('taiwan-injection', 'Share Capital', '股本', 'Q', 'TWD', 'Equity', 'posting', FALSE),
    ('taiwan-injection', 'Retained Earnings', '保留盈餘', 'Q', 'TWD', 'Equity', 'posting', FALSE),

    ('taiwan-injection', 'Sales', '銷貨收入', 'I', 'TWD', 'Income', 'group', TRUE),
    ('taiwan-injection', 'Domestic Product Sales', '國內產品銷貨收入', 'I', 'TWD', 'Sales', 'posting', FALSE),
    ('taiwan-injection', 'Export Product Sales', '外銷產品銷貨收入', 'I', 'TWD', 'Sales', 'posting', FALSE),
    ('taiwan-injection', 'Scrap Sales', '廢料銷貨收入', 'I', 'TWD', 'Sales', 'posting', FALSE),

    ('taiwan-injection', 'Cost of Goods Sold', '銷貨成本', 'E', 'TWD', 'Expenses', 'group', TRUE),
    ('taiwan-injection', 'Enclosure COGS', '感測器外殼銷貨成本', 'E', 'TWD', 'Cost of Goods Sold', 'posting', FALSE),
    ('taiwan-injection', 'Gear COGS', '精密齒輪銷貨成本', 'E', 'TWD', 'Cost of Goods Sold', 'posting', FALSE),
    ('taiwan-injection', 'Manufacturing Costs', '製造成本', 'E', 'TWD', 'Expenses', 'group', TRUE),
    ('taiwan-injection', 'Direct Labour Clearing', '直接人工轉列', 'E', 'TWD', 'Manufacturing Costs', 'posting', FALSE),
    ('taiwan-injection', 'Factory Overhead Clearing', '製造費用轉列', 'E', 'TWD', 'Manufacturing Costs', 'posting', FALSE),
    ('taiwan-injection', 'Factory Depreciation', '工廠設備折舊', 'E', 'TWD', 'Manufacturing Costs', 'posting', FALSE),
    ('taiwan-injection', 'Administration', '管理費用', 'E', 'TWD', 'Expenses', 'group', TRUE),
    ('taiwan-injection', 'Office Salaries', '辦公室薪資', 'E', 'TWD', 'Administration', 'posting', FALSE),
    ('taiwan-injection', 'Professional Fees', '專業服務費', 'E', 'TWD', 'Administration', 'posting', FALSE),
    ('taiwan-injection', 'Client Entertainment', '交際費', 'E', 'TWD', 'Administration', 'posting', FALSE);

INSERT INTO cash_accounts (book_id, acct)
VALUES ('taiwan-injection', 'Operating Bank');

INSERT INTO taiwan_account_income_tax_mappings (
    book_id, acct, treatment_id, inclusion_percent
) VALUES
    ('taiwan-injection', 'Domestic Product Sales', 'taxable_income', 1),
    ('taiwan-injection', 'Export Product Sales', 'taxable_income', 1),
    ('taiwan-injection', 'Scrap Sales', 'taxable_income', 1),
    ('taiwan-injection', 'Enclosure COGS', 'deductible_expense', 1),
    ('taiwan-injection', 'Gear COGS', 'deductible_expense', 1),
    ('taiwan-injection', 'Direct Labour Clearing', 'deductible_expense', 1),
    ('taiwan-injection', 'Factory Overhead Clearing', 'deductible_expense', 1),
    ('taiwan-injection', 'Factory Depreciation', 'capital_or_depreciation', 1),
    ('taiwan-injection', 'Office Salaries', 'deductible_expense', 1),
    ('taiwan-injection', 'Professional Fees', 'deductible_expense', 1),
    ('taiwan-injection', 'Client Entertainment', 'non_deductible_expense', 1);

INSERT INTO taiwan_account_business_tax_mappings (
    book_id, acct, direction, treatment_id
) VALUES
    ('taiwan-injection', 'Domestic Product Sales', 'sale', 'sale_standard'),
    ('taiwan-injection', 'Export Product Sales', 'sale', 'sale_zero_rated'),
    ('taiwan-injection', 'Scrap Sales', 'sale', 'sale_standard'),
    ('taiwan-injection', 'ABS Resin Inventory', 'purchase', 'purchase_creditable'),
    ('taiwan-injection', 'PP Resin Inventory', 'purchase', 'purchase_creditable'),
    ('taiwan-injection', 'Colour Masterbatch Inventory', 'purchase', 'purchase_creditable'),
    ('taiwan-injection', 'Packaging Inventory', 'purchase', 'purchase_creditable'),
    ('taiwan-injection', 'IMM-180 Asset', 'purchase', 'purchase_creditable'),
    ('taiwan-injection', 'Enclosure Mould Asset', 'purchase', 'purchase_creditable'),
    ('taiwan-injection', 'Gear Mould Asset', 'purchase', 'purchase_creditable'),
    ('taiwan-injection', 'Factory Overhead Clearing', 'purchase', 'purchase_creditable'),
    ('taiwan-injection', 'Professional Fees', 'purchase', 'purchase_creditable');

INSERT INTO trade_parties (
    book_id, id, name, is_customer, is_supplier, company_number,
    vat_number, default_terms_days
) VALUES
    ('taiwan-injection', 'taipei-controls', '台北控制股份有限公司', TRUE, FALSE, '24567891', '24567891', 30),
    ('taiwan-injection', 'osaka-components', '大阪零組件株式會社', TRUE, FALSE, NULL, NULL, 45),
    ('taiwan-injection', 'polymer-supply', '台灣高分子原料有限公司', FALSE, TRUE, '11223344', '11223344', 30),
    ('taiwan-injection', 'tooling-works', '桃園模具工業有限公司', FALSE, TRUE, '66778899', '66778899', 30),
    ('taiwan-injection', 'power-company', '台灣電力公司', FALSE, TRUE, NULL, NULL, 15),
    ('taiwan-injection', 'accountant', '陳吳會計事務所', FALSE, TRUE, '87654321', '87654321', 30);

INSERT INTO taiwan_manufacturing_profiles (
    book_id, enabled_on, inventory_cost_method, notes
) VALUES (
    'taiwan-injection', '2026-01-01', 'weighted_average',
    '數量資料用於生產及成本明細表；金額仍以帳簿過帳分錄為準。'
);

INSERT INTO taiwan_inventory_items (
    book_id, id, name, item_kind, unit, inventory_acct, product_code
) VALUES
    ('taiwan-injection', 'abs-natural', 'ABS 本色樹脂', 'raw_material', '公斤', 'ABS Resin Inventory', 'RM-ABS-NAT'),
    ('taiwan-injection', 'pp-black', 'PP 黑色樹脂', 'raw_material', '公斤', 'PP Resin Inventory', 'RM-PP-BLK'),
    ('taiwan-injection', 'blue-masterbatch', '藍色色母粒', 'raw_material', '公斤', 'Colour Masterbatch Inventory', 'RM-MB-BLU'),
    ('taiwan-injection', 'carton-small', '小型外銷紙箱', 'consumable', '個', 'Packaging Inventory', 'PK-CARTON-S'),
    ('taiwan-injection', 'factory-wip', '工廠在製品', 'work_in_progress', '批', 'Work in Progress', 'WIP'),
    ('taiwan-injection', 'sensor-enclosure', 'ABS 感測器外殼', 'finished_good', '個', 'Enclosure Inventory', 'FG-ENC-100'),
    ('taiwan-injection', 'precision-gear', 'PP 精密齒輪', 'finished_good', '個', 'Gear Inventory', 'FG-GEAR-20'),
    ('taiwan-injection', 'mixed-scrap', '可回收混合廢塑料', 'scrap', '公斤', 'Recoverable Scrap', 'SCRAP-MIX');

INSERT INTO taiwan_boms (
    book_id, id, product_item_id, output_quantity, effective_from
) VALUES
    ('taiwan-injection', 'BOM-ENC-2026', 'sensor-enclosure', 1000, '2026-01-01'),
    ('taiwan-injection', 'BOM-GEAR-2026', 'precision-gear', 800, '2026-01-01');

INSERT INTO taiwan_bom_lines (
    book_id, bom_id, material_item_id, quantity, expected_scrap_percent
) VALUES
    ('taiwan-injection', 'BOM-ENC-2026', 'abs-natural', 200, 0.03),
    ('taiwan-injection', 'BOM-ENC-2026', 'blue-masterbatch', 5, 0.02),
    ('taiwan-injection', 'BOM-ENC-2026', 'carton-small', 1000, 0),
    ('taiwan-injection', 'BOM-GEAR-2026', 'pp-black', 240, 0.025),
    ('taiwan-injection', 'BOM-GEAR-2026', 'blue-masterbatch', 4, 0.02),
    ('taiwan-injection', 'BOM-GEAR-2026', 'carton-small', 800, 0);

INSERT INTO taiwan_equipment_assets (
    book_id, id, name, equipment_kind, asset_acct,
    accumulated_depreciation_acct, depreciation_expense_acct,
    serial_number, acquired_on, in_service_on, useful_life_months, location
) VALUES
    ('taiwan-injection', 'imm-180', 'IMM-180 射出成型機', 'injection_machine',
        'IMM-180 Asset', 'Equipment Accumulated Depreciation', 'Factory Depreciation',
        'TW-IMM180-0241', '2025-12-15', '2026-01-05', 84, '第一生產區'),
    ('taiwan-injection', 'mould-enclosure', '感測器外殼四穴模具', 'mould',
        'Enclosure Mould Asset', 'Equipment Accumulated Depreciation', 'Factory Depreciation',
        'M-ENC-4C-01', '2025-12-20', '2026-01-05', 48, '模具架 A'),
    ('taiwan-injection', 'mould-gear', '精密齒輪八穴模具', 'mould',
        'Gear Mould Asset', 'Equipment Accumulated Depreciation', 'Factory Depreciation',
        'M-GEAR-8C-01', '2025-12-20', '2026-01-05', 48, '模具架 A');

INSERT INTO taiwan_manufacturing_account_mappings (
    book_id, acct, cost_category
) VALUES
    ('taiwan-injection', 'ABS Resin Inventory', 'direct_material'),
    ('taiwan-injection', 'PP Resin Inventory', 'direct_material'),
    ('taiwan-injection', 'Colour Masterbatch Inventory', 'direct_material'),
    ('taiwan-injection', 'Packaging Inventory', 'direct_material'),
    ('taiwan-injection', 'Direct Labour Clearing', 'direct_labour'),
    ('taiwan-injection', 'Factory Overhead Clearing', 'manufacturing_overhead'),
    ('taiwan-injection', 'Work in Progress', 'work_in_progress'),
    ('taiwan-injection', 'Enclosure Inventory', 'finished_goods'),
    ('taiwan-injection', 'Gear Inventory', 'finished_goods'),
    ('taiwan-injection', 'Enclosure COGS', 'cost_of_goods_sold'),
    ('taiwan-injection', 'Gear COGS', 'cost_of_goods_sold');

INSERT INTO taiwan_production_runs (
    book_id, id, product_item_id, bom_id, started_at, completed_at,
    planned_quantity, good_quantity, reject_quantity, machine_id, mould_id,
    status, notes
) VALUES
    ('taiwan-injection', 'RUN-ENC-001', 'sensor-enclosure', 'BOM-ENC-2026',
        '2026-02-02 08:00', '2026-02-03 16:00', 1000, 950, 50,
        'imm-180', 'mould-enclosure', 'completed', '首批感測器外殼生產製令。'),
    ('taiwan-injection', 'RUN-GEAR-001', 'precision-gear', 'BOM-GEAR-2026',
        '2026-03-10 08:00', '2026-03-11 14:00', 800, 780, 20,
        'imm-180', 'mould-gear', 'completed', '首批精密齒輪生產製令。');

DO $$
DECLARE
    seed_xid INTEGER;
    equipment_xid INTEGER;
    enclosure_mould_xid INTEGER;
    gear_mould_xid INTEGER;
    abs_purchase_xid INTEGER;
    pp_purchase_xid INTEGER;
    colour_purchase_xid INTEGER;
    packaging_purchase_xid INTEGER;
    enclosure_issue_xid INTEGER;
    enclosure_labour_xid INTEGER;
    enclosure_labour_allocate_xid INTEGER;
    enclosure_overhead_xid INTEGER;
    enclosure_overhead_allocate_xid INTEGER;
    enclosure_complete_xid INTEGER;
    gear_issue_xid INTEGER;
    gear_labour_xid INTEGER;
    gear_labour_allocate_xid INTEGER;
    gear_overhead_xid INTEGER;
    gear_overhead_allocate_xid INTEGER;
    gear_complete_xid INTEGER;
    enclosure_sale_xid INTEGER;
    gear_sale_xid INTEGER;
    export_sale_xid INTEGER;
    customer_payment_xid INTEGER;
    supplier_payment_xid INTEGER;
    accountant_xid INTEGER;
BEGIN
    INSERT INTO xactions (book_id, date, comment)
    VALUES ('taiwan-injection', '2026-01-02', '股東投入股本')
    RETURNING xid INTO seed_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('taiwan-injection', seed_xid, 'Operating Bank', 5000000),
        ('taiwan-injection', seed_xid, 'Share Capital', -5000000);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('taiwan-injection', '2026-01-05', '購置射出成型機')
    RETURNING xid INTO equipment_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('taiwan-injection', equipment_xid, 'IMM-180 Asset', 1500000),
        ('taiwan-injection', equipment_xid, 'Input Business Tax', 75000),
        ('taiwan-injection', equipment_xid, 'Operating Bank', -1575000);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('taiwan-injection', '2026-01-06', '購置感測器外殼模具')
    RETURNING xid INTO enclosure_mould_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('taiwan-injection', enclosure_mould_xid, 'Enclosure Mould Asset', 400000),
        ('taiwan-injection', enclosure_mould_xid, 'Input Business Tax', 20000),
        ('taiwan-injection', enclosure_mould_xid, 'Operating Bank', -420000);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('taiwan-injection', '2026-01-06', '購置精密齒輪模具')
    RETURNING xid INTO gear_mould_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('taiwan-injection', gear_mould_xid, 'Gear Mould Asset', 200000),
        ('taiwan-injection', gear_mould_xid, 'Input Business Tax', 10000),
        ('taiwan-injection', gear_mould_xid, 'Operating Bank', -210000);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('taiwan-injection', '2026-01-12', '進貨 ABS 樹脂')
    RETURNING xid INTO abs_purchase_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('taiwan-injection', abs_purchase_xid, 'ABS Resin Inventory', 30000),
        ('taiwan-injection', abs_purchase_xid, 'Input Business Tax', 1500),
        ('taiwan-injection', abs_purchase_xid, 'Trade Payables', -31500);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('taiwan-injection', '2026-01-13', '進貨 PP 樹脂')
    RETURNING xid INTO pp_purchase_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('taiwan-injection', pp_purchase_xid, 'PP Resin Inventory', 28800),
        ('taiwan-injection', pp_purchase_xid, 'Input Business Tax', 1440),
        ('taiwan-injection', pp_purchase_xid, 'Trade Payables', -30240);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('taiwan-injection', '2026-01-14', '進貨色母粒')
    RETURNING xid INTO colour_purchase_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('taiwan-injection', colour_purchase_xid, 'Colour Masterbatch Inventory', 8000),
        ('taiwan-injection', colour_purchase_xid, 'Input Business Tax', 400),
        ('taiwan-injection', colour_purchase_xid, 'Trade Payables', -8400);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('taiwan-injection', '2026-01-15', '進貨包裝材料')
    RETURNING xid INTO packaging_purchase_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('taiwan-injection', packaging_purchase_xid, 'Packaging Inventory', 10000),
        ('taiwan-injection', packaging_purchase_xid, 'Input Business Tax', 500),
        ('taiwan-injection', packaging_purchase_xid, 'Trade Payables', -10500);

    INSERT INTO taiwan_inventory_movements (
        book_id, id, item_id, movement_date, movement_kind, quantity, xid
    ) VALUES
        ('taiwan-injection', 'MV-ABS-PUR-01', 'abs-natural', '2026-01-12', 'purchase', 500, abs_purchase_xid),
        ('taiwan-injection', 'MV-PP-PUR-01', 'pp-black', '2026-01-13', 'purchase', 600, pp_purchase_xid),
        ('taiwan-injection', 'MV-MB-PUR-01', 'blue-masterbatch', '2026-01-14', 'purchase', 40, colour_purchase_xid),
        ('taiwan-injection', 'MV-PKG-PUR-01', 'carton-small', '2026-01-15', 'purchase', 5000, packaging_purchase_xid);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('taiwan-injection', '2026-02-02', '製令 RUN-ENC-001 生產領料')
    RETURNING xid INTO enclosure_issue_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('taiwan-injection', enclosure_issue_xid, 'Work in Progress', 15000),
        ('taiwan-injection', enclosure_issue_xid, 'ABS Resin Inventory', -12000),
        ('taiwan-injection', enclosure_issue_xid, 'Colour Masterbatch Inventory', -1000),
        ('taiwan-injection', enclosure_issue_xid, 'Packaging Inventory', -2000);

    INSERT INTO taiwan_inventory_movements (
        book_id, id, item_id, movement_date, movement_kind, quantity, xid,
        production_run_id
    ) VALUES
        ('taiwan-injection', 'MV-ENC-ABS', 'abs-natural', '2026-02-02', 'production_issue', 200, enclosure_issue_xid, 'RUN-ENC-001'),
        ('taiwan-injection', 'MV-ENC-MB', 'blue-masterbatch', '2026-02-02', 'production_issue', 5, enclosure_issue_xid, 'RUN-ENC-001'),
        ('taiwan-injection', 'MV-ENC-PKG', 'carton-small', '2026-02-02', 'production_issue', 1000, enclosure_issue_xid, 'RUN-ENC-001');

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('taiwan-injection', '2026-02-03', '製令 RUN-ENC-001 直接生產薪資')
    RETURNING xid INTO enclosure_labour_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('taiwan-injection', enclosure_labour_xid, 'Direct Labour Clearing', 20000),
        ('taiwan-injection', enclosure_labour_xid, 'Withholding Tax Payable', -1000),
        ('taiwan-injection', enclosure_labour_xid, 'Operating Bank', -19000);

    INSERT INTO taiwan_withholding_payments (
        book_id, id, paid_on, recipient_name, recipient_tax_id,
        recipient_residency, category_id, xid, gross_acct,
        withholding_acct, certificate_reference
    ) VALUES (
        'taiwan-injection', 'WH-2026-02-PROD', '2026-02-03',
        '2 月生產團隊', NULL, 'resident', 'salary',
        enclosure_labour_xid, 'Direct Labour Clearing',
        'Withholding Tax Payable', '2026-PAYROLL-02'
    );

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('taiwan-injection', '2026-02-03', '製令 RUN-ENC-001 人工成本分攤')
    RETURNING xid INTO enclosure_labour_allocate_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('taiwan-injection', enclosure_labour_allocate_xid, 'Work in Progress', 20000),
        ('taiwan-injection', enclosure_labour_allocate_xid, 'Direct Labour Clearing', -20000);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('taiwan-injection', '2026-02-03', '製令 RUN-ENC-001 工廠電費')
    RETURNING xid INTO enclosure_overhead_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('taiwan-injection', enclosure_overhead_xid, 'Factory Overhead Clearing', 10000),
        ('taiwan-injection', enclosure_overhead_xid, 'Input Business Tax', 500),
        ('taiwan-injection', enclosure_overhead_xid, 'Operating Bank', -10500);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('taiwan-injection', '2026-02-03', '製令 RUN-ENC-001 製造費用分攤')
    RETURNING xid INTO enclosure_overhead_allocate_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('taiwan-injection', enclosure_overhead_allocate_xid, 'Work in Progress', 10000),
        ('taiwan-injection', enclosure_overhead_allocate_xid, 'Factory Overhead Clearing', -10000);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('taiwan-injection', '2026-02-03', '製令 RUN-ENC-001 完工入庫')
    RETURNING xid INTO enclosure_complete_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('taiwan-injection', enclosure_complete_xid, 'Enclosure Inventory', 45000),
        ('taiwan-injection', enclosure_complete_xid, 'Work in Progress', -45000);
    INSERT INTO taiwan_inventory_movements (
        book_id, id, item_id, movement_date, movement_kind, quantity, xid,
        production_run_id
    ) VALUES (
        'taiwan-injection', 'MV-ENC-FG', 'sensor-enclosure', '2026-02-03',
        'production_receipt', 950, enclosure_complete_xid, 'RUN-ENC-001'
    );

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('taiwan-injection', '2026-03-10', '製令 RUN-GEAR-001 生產領料')
    RETURNING xid INTO gear_issue_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('taiwan-injection', gear_issue_xid, 'Work in Progress', 13920),
        ('taiwan-injection', gear_issue_xid, 'PP Resin Inventory', -11520),
        ('taiwan-injection', gear_issue_xid, 'Colour Masterbatch Inventory', -800),
        ('taiwan-injection', gear_issue_xid, 'Packaging Inventory', -1600);
    INSERT INTO taiwan_inventory_movements (
        book_id, id, item_id, movement_date, movement_kind, quantity, xid,
        production_run_id
    ) VALUES
        ('taiwan-injection', 'MV-GEAR-PP', 'pp-black', '2026-03-10', 'production_issue', 240, gear_issue_xid, 'RUN-GEAR-001'),
        ('taiwan-injection', 'MV-GEAR-MB', 'blue-masterbatch', '2026-03-10', 'production_issue', 4, gear_issue_xid, 'RUN-GEAR-001'),
        ('taiwan-injection', 'MV-GEAR-PKG', 'carton-small', '2026-03-10', 'production_issue', 800, gear_issue_xid, 'RUN-GEAR-001');

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('taiwan-injection', '2026-03-11', '製令 RUN-GEAR-001 直接生產薪資')
    RETURNING xid INTO gear_labour_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('taiwan-injection', gear_labour_xid, 'Direct Labour Clearing', 15000),
        ('taiwan-injection', gear_labour_xid, 'Withholding Tax Payable', -750),
        ('taiwan-injection', gear_labour_xid, 'Operating Bank', -14250);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('taiwan-injection', '2026-03-11', '製令 RUN-GEAR-001 人工成本分攤')
    RETURNING xid INTO gear_labour_allocate_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('taiwan-injection', gear_labour_allocate_xid, 'Work in Progress', 15000),
        ('taiwan-injection', gear_labour_allocate_xid, 'Direct Labour Clearing', -15000);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('taiwan-injection', '2026-03-11', '製令 RUN-GEAR-001 工廠製造費用')
    RETURNING xid INTO gear_overhead_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('taiwan-injection', gear_overhead_xid, 'Factory Overhead Clearing', 8000),
        ('taiwan-injection', gear_overhead_xid, 'Input Business Tax', 400),
        ('taiwan-injection', gear_overhead_xid, 'Operating Bank', -8400);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('taiwan-injection', '2026-03-11', '製令 RUN-GEAR-001 製造費用分攤')
    RETURNING xid INTO gear_overhead_allocate_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('taiwan-injection', gear_overhead_allocate_xid, 'Work in Progress', 8000),
        ('taiwan-injection', gear_overhead_allocate_xid, 'Factory Overhead Clearing', -8000);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('taiwan-injection', '2026-03-11', '製令 RUN-GEAR-001 完工入庫')
    RETURNING xid INTO gear_complete_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('taiwan-injection', gear_complete_xid, 'Gear Inventory', 36920),
        ('taiwan-injection', gear_complete_xid, 'Work in Progress', -36920);
    INSERT INTO taiwan_inventory_movements (
        book_id, id, item_id, movement_date, movement_kind, quantity, xid,
        production_run_id
    ) VALUES (
        'taiwan-injection', 'MV-GEAR-FG', 'precision-gear', '2026-03-11',
        'production_receipt', 780, gear_complete_xid, 'RUN-GEAR-001'
    );

    INSERT INTO taiwan_production_run_transactions (
        book_id, production_run_id, xid, transaction_role
    ) VALUES
        ('taiwan-injection', 'RUN-ENC-001', enclosure_issue_xid, 'material_issue'),
        ('taiwan-injection', 'RUN-ENC-001', enclosure_labour_allocate_xid, 'labour_allocation'),
        ('taiwan-injection', 'RUN-ENC-001', enclosure_overhead_allocate_xid, 'overhead_allocation'),
        ('taiwan-injection', 'RUN-ENC-001', enclosure_complete_xid, 'completion'),
        ('taiwan-injection', 'RUN-GEAR-001', gear_issue_xid, 'material_issue'),
        ('taiwan-injection', 'RUN-GEAR-001', gear_labour_allocate_xid, 'labour_allocation'),
        ('taiwan-injection', 'RUN-GEAR-001', gear_overhead_allocate_xid, 'overhead_allocation'),
        ('taiwan-injection', 'RUN-GEAR-001', gear_complete_xid, 'completion');

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('taiwan-injection', '2026-04-08', '國內銷售－感測器外殼')
    RETURNING xid INTO enclosure_sale_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('taiwan-injection', enclosure_sale_xid, 'Trade Receivables', 94500),
        ('taiwan-injection', enclosure_sale_xid, 'Domestic Product Sales', -90000),
        ('taiwan-injection', enclosure_sale_xid, 'Output Business Tax', -4500),
        ('taiwan-injection', enclosure_sale_xid, 'Enclosure COGS', 28421.05),
        ('taiwan-injection', enclosure_sale_xid, 'Enclosure Inventory', -28421.05);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('taiwan-injection', '2026-05-12', '國內銷售－精密齒輪')
    RETURNING xid INTO gear_sale_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('taiwan-injection', gear_sale_xid, 'Trade Receivables', 67200),
        ('taiwan-injection', gear_sale_xid, 'Domestic Product Sales', -64000),
        ('taiwan-injection', gear_sale_xid, 'Output Business Tax', -3200),
        ('taiwan-injection', gear_sale_xid, 'Gear COGS', 18933.33),
        ('taiwan-injection', gear_sale_xid, 'Gear Inventory', -18933.33);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('taiwan-injection', '2026-06-18', '外銷－感測器外殼')
    RETURNING xid INTO export_sale_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('taiwan-injection', export_sale_xid, 'Trade Receivables', 20000),
        ('taiwan-injection', export_sale_xid, 'Export Product Sales', -20000),
        ('taiwan-injection', export_sale_xid, 'Enclosure COGS', 4736.84),
        ('taiwan-injection', export_sale_xid, 'Enclosure Inventory', -4736.84);

    INSERT INTO taiwan_inventory_movements (
        book_id, id, item_id, movement_date, movement_kind, quantity, xid
    ) VALUES
        ('taiwan-injection', 'MV-ENC-SALE-01', 'sensor-enclosure', '2026-04-08', 'sale', 600, enclosure_sale_xid),
        ('taiwan-injection', 'MV-GEAR-SALE-01', 'precision-gear', '2026-05-12', 'sale', 400, gear_sale_xid),
        ('taiwan-injection', 'MV-ENC-EXPORT-01', 'sensor-enclosure', '2026-06-18', 'sale', 100, export_sale_xid);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('taiwan-injection', '2026-05-05', '客戶部分付款')
    RETURNING xid INTO customer_payment_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('taiwan-injection', customer_payment_xid, 'Operating Bank', 70000),
        ('taiwan-injection', customer_payment_xid, 'Trade Receivables', -70000);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('taiwan-injection', '2026-02-10', '支付供應商部分貨款')
    RETURNING xid INTO supplier_payment_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('taiwan-injection', supplier_payment_xid, 'Trade Payables', 50000),
        ('taiwan-injection', supplier_payment_xid, 'Operating Bank', -50000);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('taiwan-injection', '2026-07-20', '會計專業服務')
    RETURNING xid INTO accountant_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('taiwan-injection', accountant_xid, 'Professional Fees', 30000),
        ('taiwan-injection', accountant_xid, 'Input Business Tax', 1500),
        ('taiwan-injection', accountant_xid, 'Operating Bank', -31500);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('taiwan-injection', '2026-08-01', '工廠設備折舊')
    RETURNING xid INTO seed_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('taiwan-injection', seed_xid, 'Factory Depreciation', 100000),
        ('taiwan-injection', seed_xid, 'Equipment Accumulated Depreciation', -100000);

    INSERT INTO taiwan_uniform_invoices (
        book_id, id, invoice_number, direction, invoice_date, party_id,
        treatment_id, xid, net_acct, tax_acct, item_id, export_reference
    ) VALUES
        ('taiwan-injection', 'UI-MACHINE', 'AB12345678', 'purchase', '2026-01-05', 'tooling-works', 'purchase_creditable', equipment_xid, 'IMM-180 Asset', 'Input Business Tax', NULL, NULL),
        ('taiwan-injection', 'UI-MOULD-ENC', 'AB12345679', 'purchase', '2026-01-06', 'tooling-works', 'purchase_creditable', enclosure_mould_xid, 'Enclosure Mould Asset', 'Input Business Tax', NULL, NULL),
        ('taiwan-injection', 'UI-MOULD-GEAR', 'AB12345680', 'purchase', '2026-01-06', 'tooling-works', 'purchase_creditable', gear_mould_xid, 'Gear Mould Asset', 'Input Business Tax', NULL, NULL),
        ('taiwan-injection', 'UI-ABS', 'CD22334455', 'purchase', '2026-01-12', 'polymer-supply', 'purchase_creditable', abs_purchase_xid, 'ABS Resin Inventory', 'Input Business Tax', 'abs-natural', NULL),
        ('taiwan-injection', 'UI-PP', 'CD22334456', 'purchase', '2026-01-13', 'polymer-supply', 'purchase_creditable', pp_purchase_xid, 'PP Resin Inventory', 'Input Business Tax', 'pp-black', NULL),
        ('taiwan-injection', 'UI-MB', 'CD22334457', 'purchase', '2026-01-14', 'polymer-supply', 'purchase_creditable', colour_purchase_xid, 'Colour Masterbatch Inventory', 'Input Business Tax', 'blue-masterbatch', NULL),
        ('taiwan-injection', 'UI-PKG', 'CD22334458', 'purchase', '2026-01-15', 'polymer-supply', 'purchase_creditable', packaging_purchase_xid, 'Packaging Inventory', 'Input Business Tax', 'carton-small', NULL),
        ('taiwan-injection', 'UI-OH-ENC', 'EF33445566', 'purchase', '2026-02-03', 'power-company', 'purchase_creditable', enclosure_overhead_xid, 'Factory Overhead Clearing', 'Input Business Tax', NULL, NULL),
        ('taiwan-injection', 'UI-OH-GEAR', 'EF33445567', 'purchase', '2026-03-11', 'power-company', 'purchase_creditable', gear_overhead_xid, 'Factory Overhead Clearing', 'Input Business Tax', NULL, NULL),
        ('taiwan-injection', 'UI-SALE-ENC', 'GH44556677', 'sale', '2026-04-08', 'taipei-controls', 'sale_standard', enclosure_sale_xid, 'Domestic Product Sales', 'Output Business Tax', 'sensor-enclosure', NULL),
        ('taiwan-injection', 'UI-SALE-GEAR', 'GH44556678', 'sale', '2026-05-12', 'taipei-controls', 'sale_standard', gear_sale_xid, 'Domestic Product Sales', 'Output Business Tax', 'precision-gear', NULL),
        ('taiwan-injection', 'UI-EXPORT-ENC', 'EXP-2026-001', 'sale', '2026-06-18', 'osaka-components', 'sale_zero_rated', export_sale_xid, 'Export Product Sales', NULL, 'sensor-enclosure', 'TW-EXP-2026-001'),
        ('taiwan-injection', 'UI-ACCOUNTANT', 'JK55667788', 'purchase', '2026-07-20', 'accountant', 'purchase_creditable', accountant_xid, 'Professional Fees', 'Input Business Tax', NULL, NULL);

    INSERT INTO trade_invoices (
        book_id, id, party_id, direction, invoice_number,
        issued_on, due_on, xid, control_acct
    ) VALUES
        ('taiwan-injection', 'AR-ENC-001', 'taipei-controls', 'receivable', 'GH44556677', '2026-04-08', '2026-05-08', enclosure_sale_xid, 'Trade Receivables'),
        ('taiwan-injection', 'AR-GEAR-001', 'taipei-controls', 'receivable', 'GH44556678', '2026-05-12', '2026-06-11', gear_sale_xid, 'Trade Receivables'),
        ('taiwan-injection', 'AR-EXPORT-001', 'osaka-components', 'receivable', 'EXP-2026-001', '2026-06-18', '2026-08-02', export_sale_xid, 'Trade Receivables'),
        ('taiwan-injection', 'AP-ABS-001', 'polymer-supply', 'payable', 'CD22334455', '2026-01-12', '2026-02-11', abs_purchase_xid, 'Trade Payables'),
        ('taiwan-injection', 'AP-PP-001', 'polymer-supply', 'payable', 'CD22334456', '2026-01-13', '2026-02-12', pp_purchase_xid, 'Trade Payables');

    INSERT INTO trade_invoice_allocations (
        book_id, invoice_id, payment_xid, control_acct, amount
    ) VALUES
        ('taiwan-injection', 'AR-ENC-001', customer_payment_xid, 'Trade Receivables', 70000),
        ('taiwan-injection', 'AP-ABS-001', supplier_payment_xid, 'Trade Payables', 31500),
        ('taiwan-injection', 'AP-PP-001', supplier_payment_xid, 'Trade Payables', 18500);
END;
$$;
