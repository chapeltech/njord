-- Taiwan business and injection-moulding production pack.
--
-- This is production schema and reference data, never a demo factory. The
-- outputs are bookkeeping schedules and preparation working papers. They do
-- not determine filing obligations, create official returns, or replace a
-- Taiwan accountant, tax agent, labour specialist, or lawyer.

-- Generic Taiwan business --------------------------------------------------

CREATE TABLE taiwan_legal_forms (
    id VARCHAR PRIMARY KEY,
    label VARCHAR NOT NULL
);

CREATE TABLE taiwan_period_statuses (
    id VARCHAR PRIMARY KEY,
    label VARCHAR NOT NULL
);

CREATE TABLE taiwan_business_tax_frequencies (
    id VARCHAR PRIMARY KEY,
    label VARCHAR NOT NULL
);

CREATE TABLE taiwan_business_tax_treatments (
    id VARCHAR PRIMARY KEY,
    label VARCHAR NOT NULL,
    direction VARCHAR NOT NULL,
    rate_kind VARCHAR NOT NULL,
    rate NUMERIC(8,6) NOT NULL,
    recoverable_percent NUMERIC(8,6) NOT NULL DEFAULT 0,
    CHECK (direction IN ('sale', 'purchase')),
    CHECK (rate_kind IN (
        'standard', 'zero_rated', 'exempt', 'out_of_scope'
    )),
    CHECK (rate BETWEEN 0 AND 1),
    CHECK (recoverable_percent BETWEEN 0 AND 1)
);

CREATE TABLE taiwan_income_tax_treatments (
    id VARCHAR PRIMARY KEY,
    label VARCHAR NOT NULL,
    required_type VARCHAR REFERENCES acct_types(id),
    effect VARCHAR NOT NULL,
    CHECK (effect IN (
        'taxable_income', 'deductible_expense', 'non_deductible_expense',
        'tax_exempt_income', 'capital_or_depreciation',
        'manual_adjustment', 'excluded'
    ))
);

CREATE TABLE taiwan_withholding_categories (
    id VARCHAR PRIMARY KEY,
    label VARCHAR NOT NULL
);

INSERT INTO taiwan_legal_forms (id, label) VALUES
    ('company_limited', '股份有限公司'),
    ('limited_company', '有限公司'),
    ('sole_proprietorship', '獨資'),
    ('partnership', '合夥'),
    ('other', '其他／人工覆核');

INSERT INTO taiwan_period_statuses (id, label) VALUES
    ('open', '開啟'),
    ('prepared', '已編製'),
    ('filed', '已申報'),
    ('closed', '已結案');

INSERT INTO taiwan_business_tax_frequencies (id, label) VALUES
    ('bimonthly', '每兩個月'),
    ('monthly', '經核准按月申報'),
    ('manual_review', '其他／人工覆核');

INSERT INTO taiwan_business_tax_treatments (
    id, label, direction, rate_kind, rate, recoverable_percent
) VALUES
    ('sale_standard', '國內應稅銷售', 'sale', 'standard', 0.05, 0),
    ('sale_zero_rated', '零稅率銷售／外銷', 'sale', 'zero_rated', 0, 0),
    ('sale_exempt', '免稅銷售', 'sale', 'exempt', 0, 0),
    ('sale_out_of_scope', '非課稅範圍銷售', 'sale', 'out_of_scope', 0, 0),
    ('purchase_creditable', '可扣抵進項', 'purchase', 'standard', 0.05, 1),
    ('purchase_noncreditable', '不可扣抵進項', 'purchase', 'standard', 0.05, 0),
    ('purchase_exempt', '免稅進貨', 'purchase', 'exempt', 0, 0),
    ('purchase_out_of_scope', '非課稅範圍進貨', 'purchase', 'out_of_scope', 0, 0);

INSERT INTO taiwan_income_tax_treatments (
    id, label, required_type, effect
) VALUES
    ('taxable_income', '應稅營業收入', 'I', 'taxable_income'),
    ('tax_exempt_income', '免稅收入／覆核', 'I', 'tax_exempt_income'),
    ('deductible_expense', '可列支費用', 'E', 'deductible_expense'),
    ('non_deductible_expense', '不可列支費用', 'E', 'non_deductible_expense'),
    ('capital_or_depreciation', '資本支出或折舊覆核', NULL, 'capital_or_depreciation'),
    ('manual_adjustment', '需人工調整', NULL, 'manual_adjustment'),
    ('excluded', '不納入所得稅工作底稿', NULL, 'excluded');

INSERT INTO taiwan_withholding_categories (id, label) VALUES
    ('salary', '薪資所得'),
    ('professional_fee', '專業服務報酬'),
    ('rent', '租金'),
    ('interest', '利息'),
    ('dividend', '股利'),
    ('other', '其他／人工覆核');

CREATE TABLE taiwan_business_profiles (
    book_id VARCHAR PRIMARY KEY REFERENCES books(id),
    legal_name VARCHAR NOT NULL,
    unified_business_number VARCHAR NOT NULL,
    legal_form VARCHAR NOT NULL REFERENCES taiwan_legal_forms(id),
    business_tax_frequency VARCHAR NOT NULL
        REFERENCES taiwan_business_tax_frequencies(id),
    uses_uniform_invoices BOOLEAN NOT NULL DEFAULT TRUE,
    established_on DATE,
    responsible_person VARCHAR,
    registered_address VARCHAR,
    tax_registration_notes VARCHAR,
    notes VARCHAR,
    UNIQUE (unified_business_number),
    CHECK (btrim(legal_name) <> ''),
    CHECK (unified_business_number ~ '^[0-9]{8}$'),
    CHECK (established_on IS NULL OR isfinite(established_on))
);

CREATE TABLE taiwan_fiscal_periods (
    book_id VARCHAR NOT NULL REFERENCES taiwan_business_profiles(book_id),
    id VARCHAR NOT NULL,
    period_start DATE NOT NULL,
    period_end DATE NOT NULL,
    status VARCHAR NOT NULL REFERENCES taiwan_period_statuses(id),
    annual_income_tax_due_on DATE,
    provisional_income_tax_due_on DATE,
    undistributed_earnings_due_on DATE,
    notes VARCHAR,
    PRIMARY KEY (book_id, id),
    CHECK (btrim(id) <> ''),
    CHECK (isfinite(period_start) AND isfinite(period_end)),
    CHECK (period_start <= period_end),
    CHECK (
        (annual_income_tax_due_on IS NULL OR isfinite(annual_income_tax_due_on))
        AND (provisional_income_tax_due_on IS NULL OR isfinite(provisional_income_tax_due_on))
        AND (undistributed_earnings_due_on IS NULL OR isfinite(undistributed_earnings_due_on))
    )
);

CREATE TABLE taiwan_business_tax_periods (
    book_id VARCHAR NOT NULL REFERENCES taiwan_business_profiles(book_id),
    id VARCHAR NOT NULL,
    period_start DATE NOT NULL,
    period_end DATE NOT NULL,
    due_on DATE NOT NULL,
    status VARCHAR NOT NULL REFERENCES taiwan_period_statuses(id),
    filed_on DATE,
    payment_reference VARCHAR,
    notes VARCHAR,
    PRIMARY KEY (book_id, id),
    CHECK (btrim(id) <> ''),
    CHECK (
        isfinite(period_start) AND isfinite(period_end) AND isfinite(due_on)
        AND (filed_on IS NULL OR isfinite(filed_on))
    ),
    CHECK (period_start <= period_end),
    CHECK (due_on > period_end),
    CHECK (filed_on IS NULL OR status IN ('filed', 'closed'))
);

CREATE TABLE taiwan_account_income_tax_mappings (
    book_id VARCHAR NOT NULL,
    acct VARCHAR NOT NULL,
    treatment_id VARCHAR NOT NULL REFERENCES taiwan_income_tax_treatments(id),
    inclusion_percent NUMERIC(8,6) NOT NULL DEFAULT 1,
    notes VARCHAR,
    PRIMARY KEY (book_id, acct),
    FOREIGN KEY (book_id, acct) REFERENCES accts(book_id, id),
    CHECK (inclusion_percent BETWEEN 0 AND 1)
);

CREATE TABLE taiwan_account_business_tax_mappings (
    book_id VARCHAR NOT NULL,
    acct VARCHAR NOT NULL,
    direction VARCHAR NOT NULL,
    treatment_id VARCHAR NOT NULL REFERENCES taiwan_business_tax_treatments(id),
    notes VARCHAR,
    PRIMARY KEY (book_id, acct),
    FOREIGN KEY (book_id, acct) REFERENCES accts(book_id, id),
    CHECK (direction IN ('sale', 'purchase'))
);

CREATE TABLE taiwan_uniform_invoices (
    book_id VARCHAR NOT NULL REFERENCES taiwan_business_profiles(book_id),
    id VARCHAR NOT NULL,
    invoice_number VARCHAR NOT NULL,
    direction VARCHAR NOT NULL,
    invoice_date DATE NOT NULL,
    party_id VARCHAR,
    treatment_id VARCHAR NOT NULL REFERENCES taiwan_business_tax_treatments(id),
    xid INTEGER NOT NULL,
    net_acct VARCHAR NOT NULL,
    tax_acct VARCHAR,
    item_id VARCHAR,
    export_reference VARCHAR,
    notes VARCHAR,
    PRIMARY KEY (book_id, id),
    UNIQUE (book_id, direction, invoice_number),
    FOREIGN KEY (book_id, party_id) REFERENCES trade_parties(book_id, id),
    FOREIGN KEY (book_id, xid, net_acct)
        REFERENCES xaction_bits(book_id, xid, acct),
    FOREIGN KEY (book_id, xid, tax_acct)
        REFERENCES xaction_bits(book_id, xid, acct),
    CHECK (btrim(id) <> ''),
    CHECK (btrim(invoice_number) <> ''),
    CHECK (isfinite(invoice_date)),
    CHECK (direction IN ('sale', 'purchase'))
);

CREATE INDEX taiwan_uniform_invoices_date
    ON taiwan_uniform_invoices (book_id, invoice_date, direction);

CREATE TABLE taiwan_withholding_payments (
    book_id VARCHAR NOT NULL REFERENCES taiwan_business_profiles(book_id),
    id VARCHAR NOT NULL,
    paid_on DATE NOT NULL,
    recipient_name VARCHAR NOT NULL,
    recipient_tax_id VARCHAR,
    recipient_residency VARCHAR NOT NULL DEFAULT 'manual_review',
    category_id VARCHAR NOT NULL REFERENCES taiwan_withholding_categories(id),
    xid INTEGER NOT NULL,
    gross_acct VARCHAR NOT NULL,
    withholding_acct VARCHAR,
    certificate_reference VARCHAR,
    notes VARCHAR,
    PRIMARY KEY (book_id, id),
    FOREIGN KEY (book_id, xid, gross_acct)
        REFERENCES xaction_bits(book_id, xid, acct),
    FOREIGN KEY (book_id, xid, withholding_acct)
        REFERENCES xaction_bits(book_id, xid, acct),
    CHECK (btrim(id) <> ''),
    CHECK (btrim(recipient_name) <> ''),
    CHECK (isfinite(paid_on)),
    CHECK (recipient_residency IN ('resident', 'nonresident', 'manual_review'))
);

CREATE OR REPLACE FUNCTION validate_taiwan_fiscal_period()
RETURNS trigger AS $$
BEGIN
    PERFORM 1 FROM books WHERE id = NEW.book_id FOR UPDATE;

    IF EXISTS (
        SELECT 1
        FROM taiwan_fiscal_periods AS other
        WHERE other.book_id = NEW.book_id
          AND other.id <> NEW.id
          AND daterange(other.period_start, other.period_end, '[]')
              && daterange(NEW.period_start, NEW.period_end, '[]')
    ) THEN
        RAISE EXCEPTION '臺灣會計期間 %.% 與另一期間重疊',
            NEW.book_id, NEW.id
            USING ERRCODE = '23514',
                  CONSTRAINT = 'taiwan_fiscal_period_no_overlap';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER taiwan_fiscal_periods_validate
    BEFORE INSERT OR UPDATE OF book_id, id, period_start, period_end
    ON taiwan_fiscal_periods
    FOR EACH ROW EXECUTE FUNCTION validate_taiwan_fiscal_period();

-- Business-tax periods are report partitions too: overlapping rows would
-- count the same invoice twice. The common Book lock makes this predicate safe
-- when two sessions insert ranges concurrently.
CREATE OR REPLACE FUNCTION validate_taiwan_business_tax_period()
RETURNS trigger AS $$
BEGIN
    PERFORM 1 FROM books WHERE id = NEW.book_id FOR UPDATE;

    IF EXISTS (
        SELECT 1
        FROM taiwan_business_tax_periods AS other
        WHERE other.book_id = NEW.book_id
          AND other.id <> NEW.id
          AND daterange(other.period_start, other.period_end, '[]')
              && daterange(NEW.period_start, NEW.period_end, '[]')
    ) THEN
        RAISE EXCEPTION '臺灣營業稅期間 %.% 與另一期間重疊',
            NEW.book_id, NEW.id
            USING ERRCODE = '23514',
                  CONSTRAINT = 'taiwan_business_tax_period_no_overlap';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER taiwan_business_tax_periods_validate
    BEFORE INSERT OR UPDATE OF book_id, id, period_start, period_end
    ON taiwan_business_tax_periods
    FOR EACH ROW EXECUTE FUNCTION validate_taiwan_business_tax_period();

CREATE OR REPLACE FUNCTION validate_taiwan_account_mapping()
RETURNS trigger AS $$
DECLARE
    account_type VARCHAR;
    account_placeholder BOOLEAN;
    required_type VARCHAR;
    treatment_direction VARCHAR;
BEGIN
    PERFORM pg_advisory_xact_lock(
        hashtextextended('njord-taiwan-reference-data', 0)
    );
    PERFORM 1 FROM books WHERE id = NEW.book_id FOR UPDATE;

    SELECT accts.type, accts.placeholder
    INTO account_type, account_placeholder
    FROM accts
    WHERE accts.book_id = NEW.book_id AND accts.id = NEW.acct;

    IF account_placeholder THEN
	RAISE EXCEPTION '稅務對應必須使用可過帳科目'
	    USING ERRCODE = '23514',
		  CONSTRAINT = 'taiwan_account_mapping_posting_account';
    END IF;

    IF TG_TABLE_NAME = 'taiwan_account_income_tax_mappings' THEN
        SELECT treatment.required_type INTO required_type
        FROM taiwan_income_tax_treatments AS treatment
        WHERE treatment.id = NEW.treatment_id;
        IF required_type IS NOT NULL AND account_type <> required_type THEN
            RAISE EXCEPTION '所得稅處理 % 要求會計科目類別為 %',
                NEW.treatment_id, required_type
                USING ERRCODE = '23514',
                      CONSTRAINT = 'taiwan_income_tax_mapping_type';
        END IF;
    ELSE
        SELECT treatment.direction INTO treatment_direction
        FROM taiwan_business_tax_treatments AS treatment
        WHERE treatment.id = NEW.treatment_id;
        IF treatment_direction IS NOT NULL
           AND treatment_direction <> NEW.direction THEN
            RAISE EXCEPTION '營業稅處理的進銷項別與科目對應不一致'
                USING ERRCODE = '23514',
                      CONSTRAINT = 'taiwan_business_tax_mapping_direction';
        END IF;
	IF NEW.direction = 'sale' AND account_type <> 'I' THEN
	    RAISE EXCEPTION '銷項對應必須使用收入科目'
		USING ERRCODE = '23514',
		      CONSTRAINT = 'taiwan_business_tax_mapping_account_type';
	ELSIF NEW.direction = 'purchase' AND account_type NOT IN ('E', 'A') THEN
	    RAISE EXCEPTION '進項對應必須使用費用或資產科目'
		USING ERRCODE = '23514',
		      CONSTRAINT = 'taiwan_business_tax_mapping_account_type';
	END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER taiwan_account_income_tax_mapping_validate
    BEFORE INSERT OR UPDATE ON taiwan_account_income_tax_mappings
    FOR EACH ROW EXECUTE FUNCTION validate_taiwan_account_mapping();

CREATE TRIGGER taiwan_account_business_tax_mapping_validate
    BEFORE INSERT OR UPDATE ON taiwan_account_business_tax_mappings
    FOR EACH ROW EXECUTE FUNCTION validate_taiwan_account_mapping();

CREATE OR REPLACE FUNCTION njord.taiwan_uniform_invoice_postings_valid(
    p_book_id VARCHAR,
    p_xid INTEGER,
    p_direction VARCHAR,
    p_net_acct VARCHAR,
    p_tax_acct VARCHAR
)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM xaction_bits AS net_posting
        JOIN accts AS net_account
          ON net_account.book_id = net_posting.book_id
         AND net_account.id = net_posting.acct
        LEFT JOIN xaction_bits AS tax_posting
          ON tax_posting.book_id = net_posting.book_id
         AND tax_posting.xid = net_posting.xid
         AND tax_posting.acct = p_tax_acct
        LEFT JOIN accts AS tax_account
          ON tax_account.book_id = tax_posting.book_id
         AND tax_account.id = tax_posting.acct
        WHERE net_posting.book_id = p_book_id
          AND net_posting.xid = p_xid
          AND net_posting.acct = p_net_acct
          AND NOT net_account.placeholder
          AND CASE p_direction
              WHEN 'sale' THEN
                  net_account.type = 'I'
                  AND net_posting.amt < 0
                  AND (
                      p_tax_acct IS NULL
                      OR (
                          tax_account.type = 'L'
                          AND NOT tax_account.placeholder
                          AND tax_posting.amt < 0
                      )
                  )
              WHEN 'purchase' THEN
                  net_account.type IN ('A', 'E')
                  AND net_posting.amt > 0
                  AND (
                      p_tax_acct IS NULL
                      OR (
                          tax_account.type = 'A'
                          AND NOT tax_account.placeholder
                          AND tax_posting.amt > 0
                      )
                  )
              ELSE FALSE
          END
    );
$$;

CREATE OR REPLACE FUNCTION validate_taiwan_uniform_invoice()
RETURNS trigger AS $$
DECLARE
    posting_date DATE;
    treatment_direction VARCHAR;
    mapping_treatment VARCHAR;
BEGIN
    PERFORM pg_advisory_xact_lock(
        hashtextextended('njord-taiwan-reference-data', 0)
    );
    PERFORM 1 FROM books WHERE id = NEW.book_id FOR UPDATE;

    SELECT xactions.date::DATE INTO posting_date
    FROM xactions
    WHERE xactions.book_id = NEW.book_id AND xactions.xid = NEW.xid;
    IF posting_date IS NOT NULL AND posting_date <> NEW.invoice_date THEN
        RAISE EXCEPTION '統一發票日期與對應的帳簿交易日期不一致'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'taiwan_uniform_invoice_ledger_date';
    END IF;

    IF NOT njord.taiwan_uniform_invoice_postings_valid(
        NEW.book_id, NEW.xid, NEW.direction, NEW.net_acct, NEW.tax_acct
    ) THEN
        RAISE EXCEPTION '統一發票必須連結方向正確的銷售或進貨過帳分錄'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'taiwan_uniform_invoice_posting';
    END IF;

    SELECT direction INTO treatment_direction
    FROM taiwan_business_tax_treatments WHERE id = NEW.treatment_id;
    IF treatment_direction IS NOT NULL AND treatment_direction <> NEW.direction THEN
        RAISE EXCEPTION '統一發票的稅務處理進銷項別與發票不一致'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'taiwan_uniform_invoice_direction';
    END IF;

    SELECT treatment_id INTO mapping_treatment
    FROM taiwan_account_business_tax_mappings
    WHERE book_id = NEW.book_id AND acct = NEW.net_acct;
    IF mapping_treatment IS NOT NULL AND mapping_treatment <> NEW.treatment_id THEN
        RAISE EXCEPTION '統一發票的稅務處理與其科目對應不一致'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'taiwan_uniform_invoice_account_mapping';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER taiwan_uniform_invoices_validate
    BEFORE INSERT OR UPDATE ON taiwan_uniform_invoices
    FOR EACH ROW EXECUTE FUNCTION validate_taiwan_uniform_invoice();

CREATE OR REPLACE FUNCTION njord.taiwan_withholding_postings_valid(
    p_book_id VARCHAR,
    p_xid INTEGER,
    p_gross_acct VARCHAR,
    p_withholding_acct VARCHAR
)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM xaction_bits AS gross_posting
        JOIN accts AS gross_account
          ON gross_account.book_id = gross_posting.book_id
         AND gross_account.id = gross_posting.acct
        LEFT JOIN xaction_bits AS withholding_posting
          ON withholding_posting.book_id = gross_posting.book_id
         AND withholding_posting.xid = gross_posting.xid
         AND withholding_posting.acct = p_withholding_acct
        LEFT JOIN accts AS withholding_account
          ON withholding_account.book_id = withholding_posting.book_id
         AND withholding_account.id = withholding_posting.acct
        WHERE gross_posting.book_id = p_book_id
          AND gross_posting.xid = p_xid
          AND gross_posting.acct = p_gross_acct
          AND gross_account.type = 'E'
          AND NOT gross_account.placeholder
          AND gross_posting.amt > 0
          AND (
              p_withholding_acct IS NULL
              OR (
                  withholding_account.type = 'L'
                  AND NOT withholding_account.placeholder
                  AND withholding_posting.amt < 0
              )
          )
    );
$$;

CREATE OR REPLACE FUNCTION validate_taiwan_withholding_payment()
RETURNS trigger AS $$
DECLARE
    ledger_date DATE;
BEGIN
    PERFORM 1 FROM books WHERE id = NEW.book_id FOR UPDATE;

    SELECT xactions.date::DATE INTO ledger_date
    FROM xactions
    WHERE xactions.book_id = NEW.book_id
      AND xactions.xid = NEW.xid;

    IF ledger_date IS NOT NULL AND ledger_date <> NEW.paid_on THEN
        RAISE EXCEPTION '扣繳給付日與對應的帳簿交易日期不一致'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'taiwan_withholding_payment_ledger_date';
    END IF;
    IF NOT njord.taiwan_withholding_postings_valid(
        NEW.book_id, NEW.xid, NEW.gross_acct, NEW.withholding_acct
    ) THEN
        RAISE EXCEPTION '扣繳給付必須連結借方費用與貸方應付扣繳稅款分錄'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'taiwan_withholding_payment_posting';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER taiwan_withholding_payments_validate
    BEFORE INSERT OR UPDATE ON taiwan_withholding_payments
    FOR EACH ROW EXECUTE FUNCTION validate_taiwan_withholding_payment();

-- Injection-moulding manufacturing extension ------------------------------

CREATE TABLE taiwan_inventory_item_kinds (
    id VARCHAR PRIMARY KEY,
    label VARCHAR NOT NULL
);

CREATE TABLE taiwan_inventory_movement_kinds (
    id VARCHAR PRIMARY KEY,
    label VARCHAR NOT NULL,
    quantity_direction INTEGER NOT NULL CHECK (quantity_direction IN (-1, 1))
);

CREATE TABLE taiwan_equipment_kinds (
    id VARCHAR PRIMARY KEY,
    label VARCHAR NOT NULL
);

CREATE TABLE taiwan_manufacturing_cost_categories (
    id VARCHAR PRIMARY KEY,
    label VARCHAR NOT NULL,
    required_type VARCHAR NOT NULL REFERENCES acct_types(id)
);

INSERT INTO taiwan_inventory_item_kinds (id, label) VALUES
    ('raw_material', '原物料'),
    ('consumable', '物料／包裝材料'),
    ('work_in_progress', '在製品'),
    ('finished_good', '製成品'),
    ('scrap', '可回收廢料');

INSERT INTO taiwan_inventory_movement_kinds (id, label, quantity_direction) VALUES
    ('purchase', '進貨入庫', 1),
    ('production_issue', '生產領料', -1),
    ('production_receipt', '生產入庫', 1),
    ('sale', '銷貨出庫', -1),
    ('return_in', '客戶退貨入庫', 1),
    ('return_out', '退回供應商', -1),
    ('adjustment_in', '盤盈', 1),
    ('adjustment_out', '盤虧', -1),
    ('scrap_receipt', '廢料回收入庫', 1),
    ('scrap_disposal', '廢料處分出庫', -1);

INSERT INTO taiwan_equipment_kinds (id, label) VALUES
    ('injection_machine', '射出成型機'),
    ('mould', '生產模具'),
    ('robot', '機器人／自動化設備'),
    ('dryer', '樹脂乾燥機'),
    ('chiller', '冷卻機／溫控設備'),
    ('other', '其他生產設備');

INSERT INTO taiwan_manufacturing_cost_categories (
    id, label, required_type
) VALUES
    ('direct_material', '直接材料', 'A'),
    ('direct_labour', '直接人工', 'E'),
    ('manufacturing_overhead', '製造費用', 'E'),
    ('work_in_progress', '在製品', 'A'),
    ('finished_goods', '製成品', 'A'),
    ('cost_of_goods_sold', '銷貨成本', 'E');

CREATE TABLE taiwan_manufacturing_profiles (
    book_id VARCHAR PRIMARY KEY REFERENCES taiwan_business_profiles(book_id),
    enabled_on DATE NOT NULL DEFAULT CURRENT_DATE,
    inventory_cost_method VARCHAR NOT NULL DEFAULT 'weighted_average',
    notes VARCHAR,
    CHECK (inventory_cost_method IN (
        'weighted_average', 'fifo', 'specific_identification'
    )),
    CHECK (isfinite(enabled_on))
);

CREATE TABLE taiwan_inventory_items (
    book_id VARCHAR NOT NULL REFERENCES taiwan_manufacturing_profiles(book_id),
    id VARCHAR NOT NULL,
    name VARCHAR NOT NULL,
    item_kind VARCHAR NOT NULL REFERENCES taiwan_inventory_item_kinds(id),
    unit VARCHAR NOT NULL,
    inventory_acct VARCHAR NOT NULL,
    product_code VARCHAR,
    active BOOLEAN NOT NULL DEFAULT TRUE,
    notes VARCHAR,
    PRIMARY KEY (book_id, id),
    UNIQUE (book_id, inventory_acct),
    FOREIGN KEY (book_id, inventory_acct) REFERENCES accts(book_id, id),
    CHECK (btrim(id) <> ''),
    CHECK (btrim(name) <> ''),
    CHECK (btrim(unit) <> '')
);

ALTER TABLE taiwan_uniform_invoices
    ADD CONSTRAINT taiwan_uniform_invoice_item
    FOREIGN KEY (book_id, item_id)
    REFERENCES taiwan_inventory_items(book_id, id);

CREATE TABLE taiwan_boms (
    book_id VARCHAR NOT NULL,
    id VARCHAR NOT NULL,
    product_item_id VARCHAR NOT NULL,
    output_quantity NUMERIC(100,5) NOT NULL DEFAULT 1,
    effective_from DATE NOT NULL,
    effective_to DATE,
    notes VARCHAR,
    PRIMARY KEY (book_id, id),
    FOREIGN KEY (book_id, product_item_id)
        REFERENCES taiwan_inventory_items(book_id, id),
    CHECK (btrim(id) <> ''),
    CHECK (
        output_quantity > 0
        AND njord.is_finite(output_quantity)
    ),
    CHECK (
        isfinite(effective_from)
        AND (effective_to IS NULL OR isfinite(effective_to))
    ),
    CHECK (effective_to IS NULL OR effective_from <= effective_to)
);

CREATE TABLE taiwan_bom_lines (
    book_id VARCHAR NOT NULL,
    bom_id VARCHAR NOT NULL,
    material_item_id VARCHAR NOT NULL,
    quantity NUMERIC(100,5) NOT NULL,
    expected_scrap_percent NUMERIC(8,6) NOT NULL DEFAULT 0,
    notes VARCHAR,
    PRIMARY KEY (book_id, bom_id, material_item_id),
    FOREIGN KEY (book_id, bom_id) REFERENCES taiwan_boms(book_id, id),
    FOREIGN KEY (book_id, material_item_id)
        REFERENCES taiwan_inventory_items(book_id, id),
    CHECK (
        quantity > 0
        AND njord.is_finite(quantity)
    ),
    CHECK (expected_scrap_percent BETWEEN 0 AND 1)
);

CREATE TABLE taiwan_equipment_assets (
    book_id VARCHAR NOT NULL REFERENCES taiwan_manufacturing_profiles(book_id),
    id VARCHAR NOT NULL,
    name VARCHAR NOT NULL,
    equipment_kind VARCHAR NOT NULL REFERENCES taiwan_equipment_kinds(id),
    asset_acct VARCHAR NOT NULL,
    accumulated_depreciation_acct VARCHAR,
    depreciation_expense_acct VARCHAR,
    serial_number VARCHAR,
    acquired_on DATE,
    in_service_on DATE,
    useful_life_months INTEGER,
    location VARCHAR,
    notes VARCHAR,
    PRIMARY KEY (book_id, id),
    UNIQUE (book_id, asset_acct),
    FOREIGN KEY (book_id, asset_acct) REFERENCES accts(book_id, id),
    FOREIGN KEY (book_id, accumulated_depreciation_acct)
        REFERENCES accts(book_id, id),
    FOREIGN KEY (book_id, depreciation_expense_acct)
        REFERENCES accts(book_id, id),
    CHECK (btrim(id) <> ''),
    CHECK (btrim(name) <> ''),
    CHECK (useful_life_months IS NULL OR useful_life_months > 0),
    CHECK (
        (acquired_on IS NULL OR isfinite(acquired_on))
        AND (in_service_on IS NULL OR isfinite(in_service_on))
    ),
    CHECK (
        accumulated_depreciation_acct IS NULL
        OR accumulated_depreciation_acct <> asset_acct
    ),
    CHECK (
        depreciation_expense_acct IS NULL
        OR depreciation_expense_acct <> asset_acct
    ),
    CHECK (in_service_on IS NULL OR acquired_on IS NULL OR acquired_on <= in_service_on)
);

CREATE TABLE taiwan_production_runs (
    book_id VARCHAR NOT NULL REFERENCES taiwan_manufacturing_profiles(book_id),
    id VARCHAR NOT NULL,
    product_item_id VARCHAR NOT NULL,
    bom_id VARCHAR,
    started_at TIMESTAMP NOT NULL,
    completed_at TIMESTAMP,
    planned_quantity NUMERIC(100,5) NOT NULL,
    good_quantity NUMERIC(100,5) NOT NULL DEFAULT 0,
    reject_quantity NUMERIC(100,5) NOT NULL DEFAULT 0,
    machine_id VARCHAR,
    mould_id VARCHAR,
    status VARCHAR NOT NULL DEFAULT 'planned',
    notes VARCHAR,
    PRIMARY KEY (book_id, id),
    FOREIGN KEY (book_id, product_item_id)
        REFERENCES taiwan_inventory_items(book_id, id),
    FOREIGN KEY (book_id, bom_id) REFERENCES taiwan_boms(book_id, id),
    FOREIGN KEY (book_id, machine_id)
        REFERENCES taiwan_equipment_assets(book_id, id),
    FOREIGN KEY (book_id, mould_id)
        REFERENCES taiwan_equipment_assets(book_id, id),
    CHECK (btrim(id) <> ''),
    CHECK (
        planned_quantity > 0
        AND njord.is_finite(planned_quantity)
    ),
    CHECK (
        good_quantity >= 0
        AND njord.is_finite(good_quantity)
    ),
    CHECK (
        reject_quantity >= 0
        AND njord.is_finite(reject_quantity)
    ),
    CHECK (
        isfinite(started_at)
        AND (completed_at IS NULL OR isfinite(completed_at))
    ),
    CHECK (completed_at IS NULL OR started_at <= completed_at),
    CHECK (status IN ('planned', 'running', 'completed', 'cancelled')),
    CHECK (status <> 'completed' OR completed_at IS NOT NULL)
);

CREATE TABLE taiwan_inventory_movements (
    book_id VARCHAR NOT NULL,
    id VARCHAR NOT NULL,
    item_id VARCHAR NOT NULL,
    movement_date DATE NOT NULL,
    movement_kind VARCHAR NOT NULL REFERENCES taiwan_inventory_movement_kinds(id),
    quantity NUMERIC(100,5) NOT NULL,
    xid INTEGER NOT NULL,
    production_run_id VARCHAR,
    notes VARCHAR,
    PRIMARY KEY (book_id, id),
    FOREIGN KEY (book_id, item_id)
        REFERENCES taiwan_inventory_items(book_id, id),
    FOREIGN KEY (book_id, xid) REFERENCES xactions(book_id, xid),
    FOREIGN KEY (book_id, production_run_id)
        REFERENCES taiwan_production_runs(book_id, id),
    CHECK (btrim(id) <> ''),
    CHECK (isfinite(movement_date)),
    CHECK (
        quantity > 0
        AND njord.is_finite(quantity)
    )
);

CREATE INDEX taiwan_inventory_movements_period
    ON taiwan_inventory_movements (book_id, movement_date, item_id);

CREATE TABLE taiwan_production_run_transactions (
    book_id VARCHAR NOT NULL,
    production_run_id VARCHAR NOT NULL,
    xid INTEGER NOT NULL,
    transaction_role VARCHAR NOT NULL,
    PRIMARY KEY (book_id, production_run_id, xid, transaction_role),
    FOREIGN KEY (book_id, production_run_id)
        REFERENCES taiwan_production_runs(book_id, id),
    FOREIGN KEY (book_id, xid) REFERENCES xactions(book_id, xid),
    CHECK (transaction_role IN (
        'material_issue', 'labour_allocation', 'overhead_allocation',
        'completion', 'scrap'
    ))
);

CREATE TABLE taiwan_manufacturing_account_mappings (
    book_id VARCHAR NOT NULL REFERENCES taiwan_manufacturing_profiles(book_id),
    acct VARCHAR NOT NULL,
    cost_category VARCHAR NOT NULL
        REFERENCES taiwan_manufacturing_cost_categories(id),
    notes VARCHAR,
    PRIMARY KEY (book_id, acct),
    FOREIGN KEY (book_id, acct) REFERENCES accts(book_id, id)
);

CREATE OR REPLACE FUNCTION validate_taiwan_equipment_asset()
RETURNS trigger AS $$
BEGIN
    PERFORM 1 FROM books WHERE id = NEW.book_id FOR UPDATE;

    IF NOT EXISTS (
        SELECT 1 FROM accts
        WHERE book_id = NEW.book_id AND id = NEW.asset_acct
          AND type = 'A' AND account_kind = 'fixed_asset' AND NOT placeholder
    ) THEN
        RAISE EXCEPTION '設備資產科目必須是可過帳的固定資產科目'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'taiwan_equipment_asset_account';
    END IF;

    IF NEW.accumulated_depreciation_acct IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM accts
        WHERE book_id = NEW.book_id
          AND id = NEW.accumulated_depreciation_acct
          AND type = 'A' AND account_kind = 'fixed_asset' AND NOT placeholder
    ) THEN
        RAISE EXCEPTION '累計折舊科目必須是可過帳的固定資產科目'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'taiwan_equipment_accumulated_depreciation_account';
    END IF;

    IF NEW.depreciation_expense_acct IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM accts
        WHERE book_id = NEW.book_id AND id = NEW.depreciation_expense_acct
          AND type = 'E' AND NOT placeholder
    ) THEN
        RAISE EXCEPTION '折舊費用科目必須是可過帳的費用科目'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'taiwan_equipment_depreciation_expense_account';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER taiwan_equipment_assets_validate
    BEFORE INSERT OR UPDATE ON taiwan_equipment_assets
    FOR EACH ROW EXECUTE FUNCTION validate_taiwan_equipment_asset();

CREATE OR REPLACE FUNCTION validate_taiwan_manufacturing_account_mapping()
RETURNS trigger AS $$
DECLARE
    expected_type VARCHAR;
BEGIN
    PERFORM pg_advisory_xact_lock(
        hashtextextended('njord-taiwan-reference-data', 0)
    );
    PERFORM 1 FROM books WHERE id = NEW.book_id FOR UPDATE;

    SELECT category.required_type INTO expected_type
    FROM taiwan_manufacturing_cost_categories AS category
    WHERE category.id = NEW.cost_category;

    IF NOT EXISTS (
        SELECT 1 FROM accts
        WHERE book_id = NEW.book_id AND id = NEW.acct
          AND type = expected_type AND NOT placeholder
    ) THEN
        RAISE EXCEPTION '製造成本類別 % 要求可過帳的 % 類科目',
            NEW.cost_category, expected_type
            USING ERRCODE = '23514',
                  CONSTRAINT = 'taiwan_manufacturing_account_mapping_type';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER taiwan_manufacturing_account_mappings_validate
    BEFORE INSERT OR UPDATE ON taiwan_manufacturing_account_mappings
    FOR EACH ROW EXECUTE FUNCTION validate_taiwan_manufacturing_account_mapping();

CREATE OR REPLACE FUNCTION validate_taiwan_inventory_item()
RETURNS trigger AS $$
BEGIN
    PERFORM 1 FROM books WHERE id = NEW.book_id FOR UPDATE;

    IF NOT EXISTS (
        SELECT 1 FROM accts
        WHERE book_id = NEW.book_id AND id = NEW.inventory_acct
          AND type = 'A' AND NOT placeholder
    ) THEN
        RAISE EXCEPTION '存貨品項科目必須是可過帳的資產科目'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'taiwan_inventory_item_account';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER taiwan_inventory_items_validate
    BEFORE INSERT OR UPDATE ON taiwan_inventory_items
    FOR EACH ROW EXECUTE FUNCTION validate_taiwan_inventory_item();

CREATE OR REPLACE FUNCTION validate_taiwan_manufacturing_relations()
RETURNS trigger AS $$
DECLARE
    product_kind VARCHAR;
    material_kind VARCHAR;
    machine_kind VARCHAR;
    mould_kind VARCHAR;
BEGIN
    PERFORM 1 FROM books WHERE id = NEW.book_id FOR UPDATE;

    IF TG_TABLE_NAME = 'taiwan_boms' THEN
        SELECT item_kind INTO product_kind FROM taiwan_inventory_items
        WHERE book_id = NEW.book_id AND id = NEW.product_item_id;
        IF product_kind <> 'finished_good' THEN
            RAISE EXCEPTION '物料清單的產品必須為製成品'
                USING ERRCODE = '23514', CONSTRAINT = 'taiwan_bom_product_kind';
        END IF;
    ELSIF TG_TABLE_NAME = 'taiwan_bom_lines' THEN
        SELECT item_kind INTO material_kind FROM taiwan_inventory_items
        WHERE book_id = NEW.book_id AND id = NEW.material_item_id;
        IF material_kind NOT IN ('raw_material', 'consumable') THEN
            RAISE EXCEPTION '物料清單明細必須使用原物料或耗用物料存貨'
                USING ERRCODE = '23514', CONSTRAINT = 'taiwan_bom_material_kind';
        END IF;
    ELSE
        SELECT item_kind INTO product_kind FROM taiwan_inventory_items
        WHERE book_id = NEW.book_id AND id = NEW.product_item_id;
        IF product_kind <> 'finished_good' THEN
            RAISE EXCEPTION '製令的產品必須為製成品'
                USING ERRCODE = '23514', CONSTRAINT = 'taiwan_production_product_kind';
        END IF;
        IF NEW.machine_id IS NOT NULL THEN
            SELECT equipment_kind INTO machine_kind FROM taiwan_equipment_assets
            WHERE book_id = NEW.book_id AND id = NEW.machine_id;
            IF machine_kind = 'mould' THEN
                RAISE EXCEPTION '生產機台不能指定為模具'
                    USING ERRCODE = '23514', CONSTRAINT = 'taiwan_production_machine_kind';
            END IF;
        END IF;
        IF NEW.mould_id IS NOT NULL THEN
            SELECT equipment_kind INTO mould_kind FROM taiwan_equipment_assets
            WHERE book_id = NEW.book_id AND id = NEW.mould_id;
            IF mould_kind <> 'mould' THEN
                RAISE EXCEPTION '生產模具必須指向模具類設備'
                    USING ERRCODE = '23514', CONSTRAINT = 'taiwan_production_mould_kind';
            END IF;
        END IF;
        IF NEW.bom_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM taiwan_boms
            WHERE book_id = NEW.book_id AND id = NEW.bom_id
              AND product_item_id = NEW.product_item_id
        ) THEN
            RAISE EXCEPTION '製令的物料清單屬於另一產品'
                USING ERRCODE = '23514', CONSTRAINT = 'taiwan_production_bom_product';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER taiwan_boms_validate
    BEFORE INSERT OR UPDATE ON taiwan_boms
    FOR EACH ROW EXECUTE FUNCTION validate_taiwan_manufacturing_relations();

CREATE TRIGGER taiwan_bom_lines_validate
    BEFORE INSERT OR UPDATE ON taiwan_bom_lines
    FOR EACH ROW EXECUTE FUNCTION validate_taiwan_manufacturing_relations();

CREATE TRIGGER taiwan_production_runs_validate
    BEFORE INSERT OR UPDATE ON taiwan_production_runs
    FOR EACH ROW EXECUTE FUNCTION validate_taiwan_manufacturing_relations();

CREATE OR REPLACE FUNCTION njord.taiwan_inventory_posting_valid(
    p_book_id VARCHAR,
    p_item_id VARCHAR,
    p_movement_kind VARCHAR,
    p_xid INTEGER
)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM taiwan_inventory_items AS item
        JOIN xaction_bits AS posting
          ON posting.book_id = item.book_id
         AND posting.xid = p_xid
         AND posting.acct = item.inventory_acct
        JOIN taiwan_inventory_movement_kinds AS kind
          ON kind.id = p_movement_kind
        WHERE item.book_id = p_book_id
          AND item.id = p_item_id
          AND sign(posting.amt) = kind.quantity_direction
    );
$$;

CREATE OR REPLACE FUNCTION validate_taiwan_inventory_movement()
RETURNS trigger AS $$
DECLARE
    ledger_date DATE;
BEGIN
    PERFORM pg_advisory_xact_lock(
        hashtextextended('njord-taiwan-reference-data', 0)
    );
    PERFORM 1 FROM books WHERE id = NEW.book_id FOR UPDATE;

    SELECT xactions.date::DATE INTO ledger_date
    FROM xactions
    WHERE xactions.book_id = NEW.book_id
      AND xactions.xid = NEW.xid;

    IF NOT njord.taiwan_inventory_posting_valid(
        NEW.book_id, NEW.item_id, NEW.movement_kind, NEW.xid
    ) THEN
        RAISE EXCEPTION '存貨異動必須有對應存貨科目的過帳分錄'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'taiwan_inventory_movement_posting';
    END IF;
    IF ledger_date <> NEW.movement_date THEN
        RAISE EXCEPTION '存貨異動日期與對應的帳簿交易日期不一致'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'taiwan_inventory_movement_date';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER taiwan_inventory_movements_validate
    BEFORE INSERT OR UPDATE ON taiwan_inventory_movements
    FOR EACH ROW EXECUTE FUNCTION validate_taiwan_inventory_movement();

-- Reference rows are editable configuration, so changes to their semantic
-- fields must preserve every existing mapping and evidence row. The shared
-- advisory lock orders reference edits with validators that consume them.
CREATE OR REPLACE FUNCTION protect_taiwan_reference_relations()
RETURNS trigger AS $$
DECLARE
    affected_book VARCHAR;
BEGIN
    PERFORM pg_advisory_xact_lock(
        hashtextextended('njord-taiwan-reference-data', 0)
    );

    FOR affected_book IN
        SELECT DISTINCT relation.book_id
        FROM (
            SELECT mapping.book_id
            FROM taiwan_account_income_tax_mappings AS mapping
            WHERE TG_TABLE_NAME = 'taiwan_income_tax_treatments'
              AND mapping.treatment_id = OLD.id
          UNION ALL
            SELECT mapping.book_id
            FROM taiwan_account_business_tax_mappings AS mapping
            WHERE TG_TABLE_NAME = 'taiwan_business_tax_treatments'
              AND mapping.treatment_id = OLD.id
          UNION ALL
            SELECT invoice.book_id
            FROM taiwan_uniform_invoices AS invoice
            WHERE TG_TABLE_NAME = 'taiwan_business_tax_treatments'
              AND invoice.treatment_id = OLD.id
          UNION ALL
            SELECT mapping.book_id
            FROM taiwan_manufacturing_account_mappings AS mapping
            WHERE TG_TABLE_NAME = 'taiwan_manufacturing_cost_categories'
              AND mapping.cost_category = OLD.id
          UNION ALL
            SELECT movement.book_id
            FROM taiwan_inventory_movements AS movement
            WHERE TG_TABLE_NAME = 'taiwan_inventory_movement_kinds'
              AND movement.movement_kind = OLD.id
        ) AS relation
        ORDER BY relation.book_id
    LOOP
        PERFORM 1 FROM books WHERE id = affected_book FOR UPDATE;
    END LOOP;

    IF TG_TABLE_NAME = 'taiwan_income_tax_treatments' THEN
	IF EXISTS (
	    SELECT 1
	    FROM taiwan_account_income_tax_mappings AS mapping
	    JOIN accts AS account
	      ON (account.book_id, account.id) = (mapping.book_id, mapping.acct)
	    WHERE mapping.treatment_id = OLD.id
	      AND NEW.required_type IS NOT NULL
	      AND account.type <> NEW.required_type
	) THEN
	    RAISE EXCEPTION '所得稅處理 % 的科目類別仍被現有對應使用', OLD.id
		USING ERRCODE = '23514',
		      CONSTRAINT = 'taiwan_income_tax_mapping_type';
	END IF;
    ELSIF TG_TABLE_NAME = 'taiwan_business_tax_treatments' THEN
	IF EXISTS (
	    SELECT 1 FROM taiwan_account_business_tax_mappings
	    WHERE treatment_id = OLD.id AND direction <> NEW.direction
	) OR EXISTS (
	    SELECT 1 FROM taiwan_uniform_invoices
	    WHERE treatment_id = OLD.id AND direction <> NEW.direction
	) THEN
	    RAISE EXCEPTION '營業稅處理 % 的進銷項別仍被現有資料使用', OLD.id
		USING ERRCODE = '23514',
		      CONSTRAINT = 'taiwan_business_tax_treatment_direction';
	END IF;
    ELSIF TG_TABLE_NAME = 'taiwan_manufacturing_cost_categories' THEN
	IF EXISTS (
	    SELECT 1
	    FROM taiwan_manufacturing_account_mappings AS mapping
	    JOIN accts AS account
	      ON (account.book_id, account.id) = (mapping.book_id, mapping.acct)
	    WHERE mapping.cost_category = OLD.id
	      AND account.type <> NEW.required_type
	) THEN
	    RAISE EXCEPTION '製造成本類別 % 的科目類別仍被現有對應使用', OLD.id
		USING ERRCODE = '23514',
		      CONSTRAINT = 'taiwan_manufacturing_account_mapping_type';
	END IF;
    ELSIF TG_TABLE_NAME = 'taiwan_inventory_movement_kinds' THEN
	IF EXISTS (
	    SELECT 1
	    FROM taiwan_inventory_movements AS movement
	    JOIN taiwan_inventory_items AS item
	      ON (item.book_id, item.id) = (movement.book_id, movement.item_id)
	    JOIN xaction_bits AS posting
	      ON (posting.book_id, posting.xid, posting.acct) =
		 (movement.book_id, movement.xid, item.inventory_acct)
	    WHERE movement.movement_kind = OLD.id
	      AND sign(posting.amt) <> NEW.quantity_direction
	) THEN
	    RAISE EXCEPTION '存貨異動類別 % 的方向與現有過帳分錄不一致', OLD.id
		USING ERRCODE = '23514',
		      CONSTRAINT = 'taiwan_inventory_movement_posting';
	END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER taiwan_income_tax_treatments_preserve_relations
    BEFORE UPDATE OF required_type ON taiwan_income_tax_treatments
    FOR EACH ROW EXECUTE FUNCTION protect_taiwan_reference_relations();

CREATE TRIGGER taiwan_business_tax_treatments_preserve_relations
    BEFORE UPDATE OF direction ON taiwan_business_tax_treatments
    FOR EACH ROW EXECUTE FUNCTION protect_taiwan_reference_relations();

CREATE TRIGGER taiwan_manufacturing_cost_categories_preserve_relations
    BEFORE UPDATE OF required_type ON taiwan_manufacturing_cost_categories
    FOR EACH ROW EXECUTE FUNCTION protect_taiwan_reference_relations();

CREATE TRIGGER taiwan_inventory_movement_kinds_preserve_relations
    BEFORE UPDATE OF quantity_direction ON taiwan_inventory_movement_kinds
    FOR EACH ROW EXECUTE FUNCTION protect_taiwan_reference_relations();

CREATE OR REPLACE FUNCTION protect_taiwan_manufacturing_relations()
RETURNS trigger AS $$
BEGIN
    PERFORM 1 FROM books WHERE id = NEW.book_id FOR UPDATE;

    IF TG_TABLE_NAME = 'taiwan_inventory_items' THEN
	IF EXISTS (
	    SELECT 1 FROM taiwan_boms
	    WHERE book_id = NEW.book_id AND product_item_id = NEW.id
	      AND NEW.item_kind <> 'finished_good'
	) OR EXISTS (
	    SELECT 1 FROM taiwan_bom_lines
	    WHERE book_id = NEW.book_id AND material_item_id = NEW.id
	      AND NEW.item_kind NOT IN ('raw_material', 'consumable')
	) OR EXISTS (
	    SELECT 1 FROM taiwan_production_runs
	    WHERE book_id = NEW.book_id AND product_item_id = NEW.id
	      AND NEW.item_kind <> 'finished_good'
	) THEN
	    RAISE EXCEPTION '存貨品項 %.% 的新類別與現有生產資料不一致', NEW.book_id, NEW.id
		USING ERRCODE = '23514',
		      CONSTRAINT = 'taiwan_inventory_item_kind_in_use';
	END IF;
    ELSIF TG_TABLE_NAME = 'taiwan_equipment_assets' THEN
	IF EXISTS (
	    SELECT 1 FROM taiwan_production_runs AS run
	    WHERE run.book_id = NEW.book_id
	      AND (
		  (run.machine_id = NEW.id AND NEW.equipment_kind = 'mould')
		  OR (run.mould_id = NEW.id AND NEW.equipment_kind <> 'mould')
	      )
	) THEN
	    RAISE EXCEPTION '設備 %.% 的新類別與現有製令不一致', NEW.book_id, NEW.id
		USING ERRCODE = '23514',
		      CONSTRAINT = 'taiwan_equipment_kind_in_use';
	END IF;
    ELSIF TG_TABLE_NAME = 'taiwan_boms' THEN
	IF EXISTS (
	    SELECT 1 FROM taiwan_production_runs
	    WHERE book_id = NEW.book_id AND bom_id = NEW.id
	      AND product_item_id <> NEW.product_item_id
	) THEN
	    RAISE EXCEPTION '物料清單 %.% 的新產品與現有製令不一致', NEW.book_id, NEW.id
		USING ERRCODE = '23514',
		      CONSTRAINT = 'taiwan_production_bom_product';
	END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER taiwan_inventory_items_preserve_manufacturing_relations
    BEFORE UPDATE OF item_kind ON taiwan_inventory_items
    FOR EACH ROW EXECUTE FUNCTION protect_taiwan_manufacturing_relations();

CREATE TRIGGER taiwan_equipment_assets_preserve_manufacturing_relations
    BEFORE UPDATE OF equipment_kind ON taiwan_equipment_assets
    FOR EACH ROW EXECUTE FUNCTION protect_taiwan_manufacturing_relations();

CREATE TRIGGER taiwan_boms_preserve_production_relations
    BEFORE UPDATE OF product_item_id ON taiwan_boms
    FOR EACH ROW EXECUTE FUNCTION protect_taiwan_manufacturing_relations();

-- Posting evidence is also protected from the ledger side. The constraint is
-- deferred so an atomic split edit may update, remove, and add lines before
-- the final invoice, withholding, and stock relationships are checked.
CREATE OR REPLACE FUNCTION njord.assert_taiwan_posting_evidence(
    p_book_id VARCHAR,
    p_xid INTEGER
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM taiwan_uniform_invoices AS invoice
        WHERE invoice.book_id = p_book_id
          AND invoice.xid = p_xid
          AND NOT njord.taiwan_uniform_invoice_postings_valid(
              invoice.book_id, invoice.xid, invoice.direction,
              invoice.net_acct, invoice.tax_acct
          )
    ) THEN
        RAISE EXCEPTION '統一發票的過帳分錄不再有效'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'taiwan_uniform_invoice_posting';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM taiwan_withholding_payments AS payment
        WHERE payment.book_id = p_book_id
          AND payment.xid = p_xid
          AND NOT njord.taiwan_withholding_postings_valid(
              payment.book_id, payment.xid, payment.gross_acct,
              payment.withholding_acct
          )
    ) THEN
        RAISE EXCEPTION '扣繳給付的過帳分錄不再有效'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'taiwan_withholding_payment_posting';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM taiwan_inventory_movements AS movement
        WHERE movement.book_id = p_book_id
          AND movement.xid = p_xid
          AND NOT njord.taiwan_inventory_posting_valid(
              movement.book_id, movement.item_id,
              movement.movement_kind, movement.xid
          )
    ) THEN
        RAISE EXCEPTION '存貨異動的過帳分錄不再有效'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'taiwan_inventory_movement_posting';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION enforce_taiwan_posting_evidence()
RETURNS trigger AS $$
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        PERFORM njord.assert_taiwan_posting_evidence(OLD.book_id, OLD.xid);
    END IF;
    IF TG_OP IN ('INSERT', 'UPDATE')
       AND (
           TG_OP = 'INSERT'
           OR (OLD.book_id, OLD.xid) IS DISTINCT FROM (NEW.book_id, NEW.xid)
       ) THEN
        PERFORM njord.assert_taiwan_posting_evidence(NEW.book_id, NEW.xid);
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER xaction_bits_preserve_taiwan_evidence
    AFTER INSERT OR UPDATE OR DELETE ON xaction_bits
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION enforce_taiwan_posting_evidence();

-- These evidence rows copy a transaction date for period reporting. Their
-- own validators protect writes from the metadata side; this deferred reverse
-- check protects direct updates to the ledger while still permitting both
-- sides to be corrected atomically in one SQL transaction.
CREATE OR REPLACE FUNCTION enforce_taiwan_ledger_dates()
RETURNS trigger AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM taiwan_uniform_invoices
        WHERE book_id = NEW.book_id AND xid = NEW.xid
          AND invoice_date <> NEW.date::DATE
    ) THEN
        RAISE EXCEPTION '交易 %.% 日期與統一發票不一致', NEW.book_id, NEW.xid
            USING ERRCODE = '23514',
                  CONSTRAINT = 'taiwan_uniform_invoice_ledger_date';
    ELSIF EXISTS (
        SELECT 1 FROM taiwan_withholding_payments
        WHERE book_id = NEW.book_id AND xid = NEW.xid
          AND paid_on <> NEW.date::DATE
    ) THEN
        RAISE EXCEPTION '交易 %.% 日期與扣繳給付不一致', NEW.book_id, NEW.xid
            USING ERRCODE = '23514',
                  CONSTRAINT = 'taiwan_withholding_payment_ledger_date';
    ELSIF EXISTS (
        SELECT 1 FROM taiwan_inventory_movements
        WHERE book_id = NEW.book_id AND xid = NEW.xid
          AND movement_date <> NEW.date::DATE
    ) THEN
        RAISE EXCEPTION '交易 %.% 日期與存貨異動不一致', NEW.book_id, NEW.xid
            USING ERRCODE = '23514',
                  CONSTRAINT = 'taiwan_inventory_movement_date';
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER xactions_preserve_taiwan_ledger_dates
    AFTER UPDATE ON xactions
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    WHEN (OLD.date IS DISTINCT FROM NEW.date)
    EXECUTE FUNCTION enforce_taiwan_ledger_dates();

-- Metadata validators protect writes to the Taiwan tables; this deferred
-- account-side check protects the same contracts from later account edits.
CREATE OR REPLACE FUNCTION enforce_taiwan_account_relations()
RETURNS trigger AS $$
DECLARE
    account accts%ROWTYPE;
BEGIN
    SELECT * INTO account
    FROM accts WHERE book_id = NEW.book_id AND id = NEW.id;
    IF NOT FOUND THEN RETURN NULL; END IF;

    IF EXISTS (
	SELECT 1
	FROM taiwan_account_income_tax_mappings AS mapping
	JOIN taiwan_income_tax_treatments AS treatment
	  ON treatment.id = mapping.treatment_id
	WHERE mapping.book_id = NEW.book_id
	  AND mapping.acct = NEW.id
	  AND (
	      account.placeholder
	      OR (treatment.required_type IS NOT NULL
		  AND treatment.required_type <> account.type)
	  )
    ) OR EXISTS (
	SELECT 1
	FROM taiwan_account_business_tax_mappings AS mapping
	WHERE mapping.book_id = NEW.book_id
	  AND mapping.acct = NEW.id
	  AND (
	      account.placeholder
	      OR (mapping.direction = 'sale' AND account.type <> 'I')
	      OR (mapping.direction = 'purchase'
		  AND account.type NOT IN ('E', 'A'))
	  )
	) OR EXISTS (
	    SELECT 1
	    FROM taiwan_manufacturing_account_mappings AS mapping
	    JOIN taiwan_manufacturing_cost_categories AS category
	      ON category.id = mapping.cost_category
	    WHERE mapping.book_id = NEW.book_id
	      AND mapping.acct = NEW.id
	      AND (
	          account.placeholder OR account.type <> category.required_type
	      )
	) THEN
	RAISE EXCEPTION '科目 %.% 與其臺灣稅務對應不相容', NEW.book_id, NEW.id
	    USING ERRCODE = '23514',
		  CONSTRAINT = 'taiwan_account_mapping_account_type';
    END IF;

    IF EXISTS (
	SELECT 1
	FROM taiwan_equipment_assets AS equipment
	WHERE equipment.book_id = NEW.book_id
	  AND equipment.asset_acct = NEW.id
	  AND (
	      account.type <> 'A' OR account.account_kind <> 'fixed_asset'
	      OR account.placeholder
	  )
    ) OR EXISTS (
	SELECT 1
	FROM taiwan_equipment_assets AS equipment
	WHERE equipment.book_id = NEW.book_id
	  AND equipment.accumulated_depreciation_acct = NEW.id
	  AND (
	      account.type <> 'A' OR account.account_kind <> 'fixed_asset'
	      OR account.placeholder
	  )
    ) OR EXISTS (
	SELECT 1
	FROM taiwan_equipment_assets AS equipment
	WHERE equipment.book_id = NEW.book_id
	  AND equipment.depreciation_expense_acct = NEW.id
	  AND (account.type <> 'E' OR account.placeholder)
    ) THEN
	RAISE EXCEPTION '科目 %.% 與其臺灣設備資產用途不相容', NEW.book_id, NEW.id
	    USING ERRCODE = '23514',
		  CONSTRAINT = 'taiwan_equipment_account_type';
    END IF;

    IF EXISTS (
	SELECT 1
	FROM taiwan_inventory_items AS item
	WHERE item.book_id = NEW.book_id
	  AND item.inventory_acct = NEW.id
	  AND (account.type <> 'A' OR account.placeholder)
    ) THEN
	RAISE EXCEPTION '存貨科目 %.% 必須維持為可過帳的資產科目', NEW.book_id, NEW.id
	    USING ERRCODE = '23514',
		  CONSTRAINT = 'taiwan_inventory_item_account';
    END IF;

    IF EXISTS (
	SELECT 1
	FROM taiwan_uniform_invoices AS invoice
	WHERE invoice.book_id = NEW.book_id
	  AND NEW.id IN (invoice.net_acct, invoice.tax_acct)
	  AND NOT njord.taiwan_uniform_invoice_postings_valid(
	      invoice.book_id, invoice.xid, invoice.direction,
	      invoice.net_acct, invoice.tax_acct
	  )
    ) OR EXISTS (
	SELECT 1
	FROM taiwan_withholding_payments AS payment
	WHERE payment.book_id = NEW.book_id
	  AND NEW.id IN (payment.gross_acct, payment.withholding_acct)
	  AND NOT njord.taiwan_withholding_postings_valid(
	      payment.book_id, payment.xid, payment.gross_acct,
	      payment.withholding_acct
	  )
    ) THEN
	RAISE EXCEPTION '科目 %.% 使臺灣交易憑證失效', NEW.book_id, NEW.id
	    USING ERRCODE = '23514',
		  CONSTRAINT = 'taiwan_posting_evidence_account';
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER accts_preserve_taiwan_relations
    AFTER UPDATE ON accts
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    WHEN (
	(OLD.type, OLD.atype, OLD.account_kind, OLD.placeholder)
	IS DISTINCT FROM
	(NEW.type, NEW.atype, NEW.account_kind, NEW.placeholder)
    )
    EXECUTE FUNCTION enforce_taiwan_account_relations();

CREATE OR REPLACE FUNCTION njord.taiwan_business_configuration_complete(
    p_book_id VARCHAR
)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM taiwan_business_profiles AS profile
        WHERE profile.book_id = p_book_id
          AND NOT EXISTS (
              SELECT 1
              FROM (VALUES
                  ('Assets'::VARCHAR, 'A'::VARCHAR),
                  ('Liabilities', 'L'),
                  ('Equity', 'Q'),
                  ('Income', 'I'),
                  ('Expenses', 'E')
              ) AS required(id, account_type)
              WHERE NOT EXISTS (
                  SELECT 1 FROM accts
                  WHERE accts.book_id = profile.book_id
                    AND accts.id = required.id
                    AND accts.type = required.account_type
                    AND accts.atype = 'TWD'
                    AND accts.parent_id IS NULL
                    AND accts.account_kind = 'root'
                    AND accts.placeholder
              )
          )
          AND EXISTS (
              SELECT 1 FROM taiwan_fiscal_periods AS period
              WHERE period.book_id = profile.book_id
          )
    );
$$;

CREATE OR REPLACE FUNCTION njord.taiwan_manufacturing_configuration_complete(
    p_book_id VARCHAR
)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
AS $$
    SELECT njord.taiwan_business_configuration_complete(p_book_id)
       AND EXISTS (
           SELECT 1 FROM taiwan_manufacturing_profiles
           WHERE book_id = p_book_id
       );
$$;

COMMENT ON TABLE taiwan_business_profiles IS
    'Taiwan bookkeeping profile; row presence does not determine legal or tax obligations.';
COMMENT ON TABLE taiwan_uniform_invoices IS
    'Uniform-invoice evidence linked to authoritative ledger postings; not an official filing dataset.';
COMMENT ON TABLE taiwan_manufacturing_profiles IS
    'Optional production-cost and inventory extension for a Taiwan manufacturer.';
COMMENT ON TABLE taiwan_inventory_movements IS
    'Operational quantities whose monetary value remains the linked inventory-account posting.';
COMMENT ON TABLE taiwan_production_runs IS
    'Production log with good and rejected quantities, machine, mould, and optional BOM.';

-- Taiwan report definitions ------------------------------------------------

CREATE VIEW taiwan_report_catalog AS
    SELECT *
    FROM (VALUES
        (300, 'taiwan-business-tax-401'::VARCHAR,
            '營業人銷售額與稅額申報書（401）工作底稿'::VARCHAR,
            '依已分類統一發票彙整本期銷售額、進貨、銷項稅額及可扣抵進項稅額；不是正式申報書。'::VARCHAR,
            'period'::VARCHAR, '臺灣營業稅'::VARCHAR,
            'taiwan_business'::VARCHAR),
        (301, 'taiwan-uniform-invoices'::VARCHAR,
            '統一發票登記簿'::VARCHAR,
            '所選期間內與總帳分錄連結的銷項及進項發票明細。'::VARCHAR,
            'period'::VARCHAR, '臺灣營業稅'::VARCHAR,
            'taiwan_business'::VARCHAR),
        (310, 'taiwan-income-tax'::VARCHAR,
            '營利事業所得稅工作底稿'::VARCHAR,
            '依明確科目對應彙整年度帳載收入及費用；不產生申報書或最終應納稅額。'::VARCHAR,
            'period'::VARCHAR, '臺灣年度申報準備'::VARCHAR,
            'taiwan_business'::VARCHAR),
        (311, 'taiwan-withholding'::VARCHAR,
            '扣繳付款明細表'::VARCHAR,
            '與總帳分錄連結的所得人、給付總額及扣繳稅額覆核資料。'::VARCHAR,
            'period'::VARCHAR, '臺灣年度申報準備'::VARCHAR,
            'taiwan_business'::VARCHAR),
        (312, 'taiwan-compliance-calendar'::VARCHAR,
            '營業及稅務覆核行事曆'::VARCHAR,
            '已記錄的營業稅、年度結算、暫繳及未分配盈餘日期；實際義務仍須由專業顧問確認。'::VARCHAR,
            'period'::VARCHAR, '臺灣年度申報準備'::VARCHAR,
            'taiwan_business'::VARCHAR),
        (320, 'taiwan-trade-aging'::VARCHAR,
            '應收及應付帳款帳齡分析'::VARCHAR,
            '依控制科目分錄及沖銷記錄列示未結清的客戶及供應商發票。'::VARCHAR,
            'as_of'::VARCHAR, '臺灣營運管理'::VARCHAR,
            'taiwan_business'::VARCHAR),
        (400, 'taiwan-inventory-rollforward'::VARCHAR,
            '存貨進銷存明細表'::VARCHAR,
            '列示原物料、物料、在製品、製成品及廢料的數量變動與期末帳載價值。'::VARCHAR,
            'period'::VARCHAR, '射出成型・存貨'::VARCHAR,
            'taiwan_manufacturing'::VARCHAR),
        (401, 'taiwan-direct-material-usage'::VARCHAR,
            '直接材料耗用分析'::VARCHAR,
            '比較物料清單標準用量、實際生產領料數量及其帳載成本。'::VARCHAR,
            'period'::VARCHAR, '射出成型・成本'::VARCHAR,
            'taiwan_manufacturing'::VARCHAR),
        (402, 'taiwan-production-cost'::VARCHAR,
            '生產成本及單位成本表'::VARCHAR,
            '依製令連結分錄彙整直接材料、直接人工、製造費用、完工成本及單位成本。'::VARCHAR,
            'period'::VARCHAR, '射出成型・成本'::VARCHAR,
            'taiwan_manufacturing'::VARCHAR),
        (403, 'taiwan-production-yield'::VARCHAR,
            '射出成型生產及良率日報'::VARCHAR,
            '列示製令、機台、模具、計畫產量、良品數、不良品數及良率。'::VARCHAR,
            'period'::VARCHAR, '射出成型・生產'::VARCHAR,
            'taiwan_manufacturing'::VARCHAR),
        (404, 'taiwan-product-margin'::VARCHAR,
            '產品毛利分析'::VARCHAR,
            '依產品列示銷售數量、發票收入、存貨成本及毛利。'::VARCHAR,
            'period'::VARCHAR, '射出成型・管理'::VARCHAR,
            'taiwan_manufacturing'::VARCHAR),
        (405, 'taiwan-equipment-register'::VARCHAR,
            '機器設備及模具明細表'::VARCHAR,
            '列示射出成型機、模具及輔助設備的帳載成本、折舊及帳面淨值。'::VARCHAR,
            'as_of'::VARCHAR, '射出成型・資產'::VARCHAR,
            'taiwan_manufacturing'::VARCHAR)
    ) AS reports(
        report_order, report_id, title, description, parameter_kind,
        report_group, profile_kind
    );

CREATE VIEW taiwan_report_columns AS
    SELECT *
    FROM (VALUES
        ('taiwan-business-tax-401'::VARCHAR, 1, 'category'::VARCHAR, '類別'::VARCHAR, 'left'::VARCHAR, 'text'::VARCHAR, FALSE),
        ('taiwan-business-tax-401', 2, 'sales', '銷售額', 'right', 'number', FALSE),
        ('taiwan-business-tax-401', 3, 'output_tax', '銷項稅額', 'right', 'number', FALSE),
        ('taiwan-business-tax-401', 4, 'purchases', '進貨及費用', 'right', 'number', FALSE),
        ('taiwan-business-tax-401', 5, 'input_tax', '可扣抵進項稅額', 'right', 'number', FALSE),
        ('taiwan-business-tax-401', 6, 'review', '依據／覆核' , 'left', 'text', FALSE),

        ('taiwan-uniform-invoices', 1, 'date', '日期', 'left', 'text', FALSE),
        ('taiwan-uniform-invoices', 2, 'invoice', '發票號碼', 'left', 'text', FALSE),
        ('taiwan-uniform-invoices', 3, 'direction', '進銷項', 'left', 'text', FALSE),
        ('taiwan-uniform-invoices', 4, 'party', '交易對象', 'left', 'text', FALSE),
        ('taiwan-uniform-invoices', 5, 'treatment', '稅務處理', 'left', 'text', FALSE),
        ('taiwan-uniform-invoices', 6, 'net', '未稅金額', 'right', 'number', FALSE),
        ('taiwan-uniform-invoices', 7, 'tax', '稅額', 'right', 'number', FALSE),
        ('taiwan-uniform-invoices', 8, 'total', '含稅金額', 'right', 'number', FALSE),

        ('taiwan-income-tax', 1, 'account', '會計科目', 'left', 'text', FALSE),
        ('taiwan-income-tax', 2, 'book_amount', '帳載金額', 'right', 'number', FALSE),
        ('taiwan-income-tax', 3, 'tax_effect', '試算課稅影響', 'right', 'number', FALSE),
        ('taiwan-income-tax', 4, 'treatment', '稅務處理／覆核', 'left', 'text', FALSE),

        ('taiwan-withholding', 1, 'date', '給付日', 'left', 'text', FALSE),
        ('taiwan-withholding', 2, 'recipient', '所得人', 'left', 'text', FALSE),
        ('taiwan-withholding', 3, 'category', '所得類別', 'left', 'text', FALSE),
        ('taiwan-withholding', 4, 'gross', '給付總額', 'right', 'number', FALSE),
        ('taiwan-withholding', 5, 'withheld', '扣繳稅額', 'right', 'number', FALSE),
        ('taiwan-withholding', 6, 'net', '實付淨額', 'right', 'number', FALSE),
        ('taiwan-withholding', 7, 'certificate', '憑單／覆核', 'left', 'text', FALSE),

        ('taiwan-compliance-calendar', 1, 'obligation', '覆核項目', 'left', 'text', FALSE),
        ('taiwan-compliance-calendar', 2, 'period', '期間', 'left', 'text', FALSE),
        ('taiwan-compliance-calendar', 3, 'due', '記錄到期日', 'left', 'text', FALSE),
        ('taiwan-compliance-calendar', 4, 'completed', '記錄完成日', 'left', 'text', FALSE),
        ('taiwan-compliance-calendar', 5, 'status', '狀態', 'left', 'text', FALSE),

        ('taiwan-trade-aging', 1, 'direction', '類型', 'left', 'text', FALSE),
        ('taiwan-trade-aging', 2, 'party', '交易對象', 'left', 'text', FALSE),
        ('taiwan-trade-aging', 3, 'invoice', '發票號碼', 'left', 'text', FALSE),
        ('taiwan-trade-aging', 4, 'due', '到期日', 'left', 'text', FALSE),
        ('taiwan-trade-aging', 5, 'gross', '原始金額', 'right', 'number', FALSE),
        ('taiwan-trade-aging', 6, 'paid', '已沖銷', 'right', 'number', FALSE),
        ('taiwan-trade-aging', 7, 'outstanding', '未結清', 'right', 'number', FALSE),
        ('taiwan-trade-aging', 8, 'age', '帳齡', 'left', 'text', FALSE),

        ('taiwan-inventory-rollforward', 1, 'item', '品項', 'left', 'text', FALSE),
        ('taiwan-inventory-rollforward', 2, 'kind', '類別', 'left', 'text', FALSE),
        ('taiwan-inventory-rollforward', 3, 'unit', '單位', 'left', 'text', FALSE),
        ('taiwan-inventory-rollforward', 4, 'opening_qty', '期初數量', 'right', 'number', FALSE),
        ('taiwan-inventory-rollforward', 5, 'receipts', '入庫數量', 'right', 'number', FALSE),
        ('taiwan-inventory-rollforward', 6, 'issues', '出庫數量', 'right', 'number', FALSE),
        ('taiwan-inventory-rollforward', 7, 'closing_qty', '期末數量', 'right', 'number', FALSE),
        ('taiwan-inventory-rollforward', 8, 'closing_value', '期末帳載價值', 'right', 'number', FALSE),

        ('taiwan-direct-material-usage', 1, 'run', '製令', 'left', 'text', FALSE),
        ('taiwan-direct-material-usage', 2, 'product', '產品', 'left', 'text', FALSE),
        ('taiwan-direct-material-usage', 3, 'material', '材料', 'left', 'text', FALSE),
        ('taiwan-direct-material-usage', 4, 'expected', 'BOM 標準用量', 'right', 'number', FALSE),
        ('taiwan-direct-material-usage', 5, 'actual', '實際領料', 'right', 'number', FALSE),
        ('taiwan-direct-material-usage', 6, 'variance', '數量差異', 'right', 'number', FALSE),
        ('taiwan-direct-material-usage', 7, 'cost', '實際帳載成本', 'right', 'number', FALSE),

        ('taiwan-production-cost', 1, 'run', '製令', 'left', 'text', FALSE),
        ('taiwan-production-cost', 2, 'product', '產品', 'left', 'text', FALSE),
        ('taiwan-production-cost', 3, 'material', '直接材料', 'right', 'number', FALSE),
        ('taiwan-production-cost', 4, 'labour', '直接人工', 'right', 'number', FALSE),
        ('taiwan-production-cost', 5, 'overhead', '製造費用', 'right', 'number', FALSE),
        ('taiwan-production-cost', 6, 'finished_cost', '完工成本', 'right', 'number', FALSE),
        ('taiwan-production-cost', 7, 'good_qty', '良品數量', 'right', 'number', FALSE),
        ('taiwan-production-cost', 8, 'unit_cost', '單位成本', 'right', 'number', FALSE),

        ('taiwan-production-yield', 1, 'date', '完工日', 'left', 'text', FALSE),
        ('taiwan-production-yield', 2, 'run', '製令', 'left', 'text', FALSE),
        ('taiwan-production-yield', 3, 'product', '產品', 'left', 'text', FALSE),
        ('taiwan-production-yield', 4, 'machine', '機台', 'left', 'text', FALSE),
        ('taiwan-production-yield', 5, 'mould', '模具', 'left', 'text', FALSE),
        ('taiwan-production-yield', 6, 'planned', '計畫產量', 'right', 'number', FALSE),
        ('taiwan-production-yield', 7, 'good', '良品數', 'right', 'number', FALSE),
        ('taiwan-production-yield', 8, 'reject', '不良品數', 'right', 'number', FALSE),
        ('taiwan-production-yield', 9, 'yield', '良率', 'right', 'percent', FALSE),

        ('taiwan-product-margin', 1, 'product', '產品', 'left', 'text', FALSE),
        ('taiwan-product-margin', 2, 'units', '銷售數量', 'right', 'number', FALSE),
        ('taiwan-product-margin', 3, 'revenue', '銷貨收入', 'right', 'number', FALSE),
        ('taiwan-product-margin', 4, 'cogs', '存貨成本', 'right', 'number', FALSE),
        ('taiwan-product-margin', 5, 'margin', '毛利', 'right', 'number', FALSE),
        ('taiwan-product-margin', 6, 'margin_percent', '毛利率', 'right', 'percent', FALSE),

        ('taiwan-equipment-register', 1, 'equipment', '設備', 'left', 'text', FALSE),
        ('taiwan-equipment-register', 2, 'kind', '類別', 'left', 'text', FALSE),
        ('taiwan-equipment-register', 3, 'in_service', '啟用日', 'left', 'text', FALSE),
        ('taiwan-equipment-register', 4, 'cost', '帳載成本', 'right', 'number', FALSE),
        ('taiwan-equipment-register', 5, 'depreciation', '累計折舊', 'right', 'number', FALSE),
        ('taiwan-equipment-register', 6, 'net_book_value', '帳面淨值', 'right', 'number', FALSE),
        ('taiwan-equipment-register', 7, 'life', '耐用年限', 'left', 'text', FALSE),
        ('taiwan-equipment-register', 8, 'location', '所在位置', 'left', 'text', FALSE)
    ) AS columns(
        report_id, column_order, column_id, label, alignment, value_format,
        tree_column
    );

CREATE OR REPLACE FUNCTION njord.taiwan_report_validation_messages(
    p_report_id VARCHAR,
    p_book_id VARCHAR,
    p_start DATE,
    p_end DATE
)
RETURNS VARCHAR[]
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    messages VARCHAR[] := ARRAY[]::VARCHAR[];
    requires_manufacturing BOOLEAN := p_report_id IN (
            'taiwan-inventory-rollforward', 'taiwan-direct-material-usage',
            'taiwan-production-cost', 'taiwan-production-yield',
            'taiwan-product-margin', 'taiwan-equipment-register'
        );
BEGIN
    IF NOT njord.taiwan_business_configuration_complete(p_book_id) THEN
        RETURN ARRAY[
            '請先在「帳簿」頁面設定臺灣營業人資料及會計期間，再開啟此工作底稿。'
        ]::VARCHAR[];
    END IF;

    IF requires_manufacturing
       AND NOT njord.taiwan_manufacturing_configuration_complete(p_book_id) THEN
        messages := array_append(
            messages,
            '請在「帳簿」頁面啟用製造業擴充功能。'
        );
    ELSIF requires_manufacturing AND NOT EXISTS (
        SELECT 1 FROM taiwan_inventory_items WHERE book_id = p_book_id
    ) THEN
        messages := array_append(
            messages,
            '使用製造業明細表前，請至少建立一個存貨品項。'
        );
    END IF;

    IF p_start IS NOT NULL AND p_end IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM taiwan_fiscal_periods
        WHERE book_id = p_book_id
          AND period_start <= p_end AND period_end >= p_start
    ) THEN
        messages := array_append(
            messages,
            '尚無已設定的臺灣會計期間涵蓋所選日期。'
        );
    END IF;

    IF p_report_id = 'taiwan-income-tax' AND EXISTS (
        SELECT 1
        FROM report_postings AS posting
	WHERE posting.book_id = p_book_id
	  AND posting.account_type IN ('I', 'E')
	  AND posting.transaction_date::DATE
	      BETWEEN COALESCE(p_start, '-infinity'::DATE)
		  AND COALESCE(p_end, 'infinity'::DATE)
	  AND NOT EXISTS (
	      SELECT 1 FROM taiwan_account_income_tax_mappings AS mapping
	      WHERE mapping.book_id = posting.book_id
		AND mapping.acct = posting.account_id
	  )
    ) THEN
        messages := array_append(
            messages,
            '未建立對應的收入或費用異動未納入所得稅小計，請人工覆核。'
        );
    END IF;

    RETURN messages;
END;
$$;

CREATE OR REPLACE FUNCTION taiwan_report_rows(
    b VARCHAR,
    requested_report VARCHAR,
    as_of_date TIMESTAMP,
    start_date TIMESTAMP,
    end_date TIMESTAMP
)
RETURNS TABLE (
    row_order BIGINT,
    row_key VARCHAR,
    payload JSONB
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF NOT njord.taiwan_business_configuration_complete(b) THEN
        RETURN;
    END IF;

    IF requested_report IN (
        'taiwan-inventory-rollforward', 'taiwan-direct-material-usage',
        'taiwan-production-cost', 'taiwan-production-yield',
        'taiwan-product-margin', 'taiwan-equipment-register'
    ) AND NOT njord.taiwan_manufacturing_configuration_complete(b) THEN
        RETURN;
    END IF;

    IF requested_report = 'taiwan-business-tax-401' THEN
        RETURN QUERY
        WITH invoice_values AS (
            SELECT
                treatment.id,
                treatment.label,
                treatment.direction,
                treatment.rate,
                treatment.recoverable_percent,
                abs(net_posting.reporting_amount)::NUMERIC AS net_amount,
		CASE WHEN tax_posting.xid IS NULL THEN 0
		     ELSE abs(tax_posting.reporting_amount)
		END::NUMERIC AS tax_amount
            FROM taiwan_uniform_invoices AS invoice
            JOIN taiwan_business_tax_treatments AS treatment
              ON treatment.id = invoice.treatment_id
            JOIN report_postings AS net_posting
              ON net_posting.book_id = invoice.book_id
             AND net_posting.xid = invoice.xid
             AND net_posting.account_id = invoice.net_acct
            LEFT JOIN report_postings AS tax_posting
              ON tax_posting.book_id = invoice.book_id
             AND tax_posting.xid = invoice.xid
             AND tax_posting.account_id = invoice.tax_acct
            WHERE invoice.book_id = b
              AND invoice.invoice_date BETWEEN start_date::DATE AND end_date::DATE
        ),
        grouped AS (
            SELECT
                id, label, direction, rate, recoverable_percent,
		njord.sum_if_complete(net_amount) AS net_amount,
		njord.sum_if_complete(tax_amount) AS tax_amount
            FROM invoice_values
            GROUP BY id, label, direction, rate, recoverable_percent
        ),
        detail AS (
            SELECT
                row_number() OVER (ORDER BY direction DESC, label, id)::BIGINT AS seq,
                id, label, direction, rate, recoverable_percent,
                net_amount, tax_amount
            FROM grouped
        ),
        totals AS (
            SELECT
		njord.sum_if_complete(net_amount)
		    FILTER (WHERE direction = 'sale') AS sales,
		njord.sum_if_complete(tax_amount)
		    FILTER (WHERE direction = 'sale') AS output_tax,
		njord.sum_if_complete(net_amount)
		    FILTER (WHERE direction = 'purchase') AS purchases,
		njord.sum_if_complete(tax_amount * recoverable_percent)
		    FILTER (WHERE direction = 'purchase') AS input_tax
            FROM grouped
        )
        SELECT
            detail.seq,
            detail.id,
	    njord.report_payload(
		'account',
		NULL,
		jsonb_build_array(
		    njord.report_text_cell('category', detail.label),
		    njord.report_number_cell('sales',
			CASE WHEN detail.direction = 'sale' THEN detail.net_amount END),
		    njord.report_number_cell('output_tax',
			CASE WHEN detail.direction = 'sale' THEN detail.tax_amount END),
		    njord.report_number_cell('purchases',
			CASE WHEN detail.direction = 'purchase' THEN detail.net_amount END),
		    njord.report_number_cell('input_tax',
			CASE WHEN detail.direction = 'purchase'
			    THEN detail.tax_amount * detail.recoverable_percent END),
		    njord.report_text_cell('review',
			'設定稅率 ' || trim(to_char(detail.rate * 100, 'FM990D00'))
			|| '%；請覆核發票適用性')
                )
            )
        FROM detail
        UNION ALL
        SELECT
            9000::BIGINT,
            'net-business-tax'::VARCHAR,
	    njord.report_payload(
		'grand_total',
		NULL,
		jsonb_build_array(
		    njord.report_text_cell('category', '工作底稿合計'),
		    njord.report_number_cell('sales', totals.sales),
		    njord.report_number_cell('output_tax', totals.output_tax),
		    njord.report_number_cell('purchases', totals.purchases),
		    njord.report_number_cell('input_tax', totals.input_tax),
		    njord.report_text_cell('review',
			'試算應納（退）稅額 '
                        || trim(to_char(totals.output_tax - totals.input_tax, 'FM999999999990D00'))
                        || ' TWD；申報 401 表前請先勾稽並覆核')
                )
            )
        FROM totals;
    ELSIF requested_report = 'taiwan-uniform-invoices' THEN
        RETURN QUERY
        SELECT
            row_number() OVER (
                ORDER BY invoice.invoice_date, invoice.direction,
                         invoice.invoice_number, invoice.id
            )::BIGINT,
            invoice.id,
	    njord.report_payload(
		'account',
		invoice.net_acct,
		jsonb_build_array(
		    njord.report_text_cell('date', invoice.invoice_date::VARCHAR),
		    njord.report_text_cell('invoice', invoice.invoice_number),
		    njord.report_text_cell('direction',
			CASE invoice.direction WHEN 'sale' THEN '銷項' ELSE '進項' END),
		    njord.report_text_cell('party', COALESCE(party.name, '未指定')),
		    njord.report_text_cell('treatment', treatment.label),
		    njord.report_number_cell('net', abs(net_bits.amt)),
		    njord.report_number_cell('tax', COALESCE(abs(tax_bits.amt), 0)),
		    njord.report_number_cell('total',
			abs(net_bits.amt) + COALESCE(abs(tax_bits.amt), 0))
                )
            )
        FROM taiwan_uniform_invoices AS invoice
        JOIN taiwan_business_tax_treatments AS treatment
          ON treatment.id = invoice.treatment_id
        JOIN xaction_bits AS net_bits
          ON net_bits.book_id = invoice.book_id
         AND net_bits.xid = invoice.xid AND net_bits.acct = invoice.net_acct
        LEFT JOIN xaction_bits AS tax_bits
          ON tax_bits.book_id = invoice.book_id
         AND tax_bits.xid = invoice.xid AND tax_bits.acct = invoice.tax_acct
        LEFT JOIN trade_parties AS party
          ON party.book_id = invoice.book_id AND party.id = invoice.party_id
        WHERE invoice.book_id = b
          AND invoice.invoice_date BETWEEN start_date::DATE AND end_date::DATE;
    ELSIF requested_report = 'taiwan-income-tax' THEN
        RETURN QUERY
        WITH postings AS (
            SELECT
		posting.account_id AS id,
		posting.account_name AS name,
		posting.account_type AS type,
		treatment.label,
		treatment.effect,
		mapping.inclusion_percent,
		CASE posting.account_type
		    WHEN 'I' THEN -posting.reporting_amount
		    ELSE posting.reporting_amount
		END AS reporting_amount,
		posting.reporting_rate
            FROM taiwan_account_income_tax_mappings AS mapping
            JOIN taiwan_income_tax_treatments AS treatment
              ON treatment.id = mapping.treatment_id
	    JOIN report_postings AS posting
	      ON posting.book_id = mapping.book_id
	     AND posting.account_id = mapping.acct
            WHERE mapping.book_id = b
	      AND posting.transaction_date BETWEEN start_date AND end_date
        ),
        mapped AS (
            SELECT
                id, name, type, label, effect, inclusion_percent,
		njord.sum_if_complete(reporting_amount) AS book_amount
            FROM postings
            GROUP BY id, name, type, label, effect, inclusion_percent
        ),
        valued AS (
	    SELECT mapped.*,
		book_amount IS NULL AS missing_rate,
		CASE WHEN book_amount IS NULL THEN NULL ELSE CASE effect
		    WHEN 'taxable_income' THEN book_amount * inclusion_percent
		    WHEN 'deductible_expense' THEN -book_amount * inclusion_percent
		    WHEN 'tax_exempt_income' THEN 0
		    WHEN 'non_deductible_expense' THEN 0
		    WHEN 'excluded' THEN 0
		    ELSE NULL
		END END::NUMERIC AS tax_effect
            FROM mapped
        ),
        numbered AS (
            SELECT row_number() OVER (ORDER BY type, name, id)::BIGINT AS seq, *
            FROM valued
        ),
        summary AS (
	    SELECT
		COALESCE(bool_or(missing_rate), FALSE) AS missing_rate,
		CASE WHEN bool_or(missing_rate) THEN NULL
		     ELSE COALESCE(sum(tax_effect), 0)
		END::NUMERIC AS indicative_result
            FROM valued
        )
        SELECT
	    seq,
	    id,
	    njord.report_payload(
		CASE WHEN missing_rate THEN 'warning' ELSE 'account' END,
		id,
		jsonb_build_array(
		    njord.report_text_cell('account', name),
		    njord.report_number_cell('book_amount', book_amount),
		    njord.report_number_cell('tax_effect', tax_effect),
		    njord.report_text_cell(
			'treatment',
			CASE WHEN missing_rate THEN label || ' · 缺少換算匯率'
			     ELSE label END
		    )
		)
	    )
        FROM numbered
        UNION ALL
        SELECT
	    9000::BIGINT,
	    'indicative-result'::VARCHAR,
	    njord.report_payload(
		CASE WHEN summary.missing_rate THEN 'warning' ELSE 'grand_total' END,
		NULL,
		jsonb_build_array(
		    njord.report_text_cell('account', '已對應科目的試算課稅所得'),
		    njord.report_number_cell('book_amount', NULL),
		    njord.report_number_cell('tax_effect', summary.indicative_result),
		    njord.report_text_cell(
			'treatment',
			CASE WHEN summary.missing_rate
			    THEN '缺少換算匯率；已停止試算以避免遺漏金額'
			    ELSE '請覆核虧損、租稅優惠、限制及調整項目；本表未計算最終應納稅額'
			END
		    )
                )
            )
        FROM summary;
    ELSIF requested_report = 'taiwan-withholding' THEN
        RETURN QUERY
        SELECT
            row_number() OVER (ORDER BY payment.paid_on, payment.id)::BIGINT,
            payment.id,
	    njord.report_payload(
		'account',
		payment.gross_acct,
		jsonb_build_array(
		    njord.report_text_cell('date', payment.paid_on::VARCHAR),
		    njord.report_text_cell('recipient', payment.recipient_name),
		    njord.report_text_cell('category', category.label),
		    njord.report_number_cell('gross', abs(gross_bits.amt)),
		    njord.report_number_cell('withheld', COALESCE(abs(withheld_bits.amt), 0)),
		    njord.report_number_cell('net',
			abs(gross_bits.amt) - COALESCE(abs(withheld_bits.amt), 0)),
		    njord.report_text_cell('certificate',
			COALESCE(payment.certificate_reference,
                            CASE payment.recipient_residency
                                WHEN 'resident' THEN '居住者・待覆核'
                                WHEN 'nonresident' THEN '非居住者・待覆核'
                                ELSE '居住身分待覆核'
                            END))
                )
            )
        FROM taiwan_withholding_payments AS payment
        JOIN taiwan_withholding_categories AS category
          ON category.id = payment.category_id
        JOIN xaction_bits AS gross_bits
          ON gross_bits.book_id = payment.book_id
         AND gross_bits.xid = payment.xid AND gross_bits.acct = payment.gross_acct
        LEFT JOIN xaction_bits AS withheld_bits
          ON withheld_bits.book_id = payment.book_id
         AND withheld_bits.xid = payment.xid
         AND withheld_bits.acct = payment.withholding_acct
        WHERE payment.book_id = b
          AND payment.paid_on BETWEEN start_date::DATE AND end_date::DATE;
    ELSIF requested_report = 'taiwan-compliance-calendar' THEN
        RETURN QUERY
        WITH calendar AS (
            SELECT
                100 + row_number() OVER (ORDER BY tax_period.due_on, tax_period.id) AS seq,
                '營業稅申報覆核'::VARCHAR AS obligation,
                tax_period.id::VARCHAR AS period_label,
                tax_period.due_on,
                tax_period.filed_on AS completed_on,
                tax_period.status::VARCHAR AS status,
                ('business-tax:' || tax_period.id)::VARCHAR AS key
            FROM taiwan_business_tax_periods AS tax_period
            WHERE tax_period.book_id = b
              AND tax_period.due_on BETWEEN start_date::DATE AND end_date::DATE
            UNION ALL
            SELECT 1000, '年度營利事業所得稅結算申報覆核',
                period.id, period.annual_income_tax_due_on, NULL::DATE,
                period.status, 'annual:' || period.id
            FROM taiwan_fiscal_periods AS period
            WHERE period.book_id = b AND period.annual_income_tax_due_on IS NOT NULL
              AND period.annual_income_tax_due_on BETWEEN start_date::DATE AND end_date::DATE
            UNION ALL
            SELECT 1010, '營利事業所得稅暫繳申報適用性覆核',
                period.id, period.provisional_income_tax_due_on, NULL::DATE,
                'review', 'provisional:' || period.id
            FROM taiwan_fiscal_periods AS period
            WHERE period.book_id = b AND period.provisional_income_tax_due_on IS NOT NULL
              AND period.provisional_income_tax_due_on BETWEEN start_date::DATE AND end_date::DATE
            UNION ALL
            SELECT 1020, '未分配盈餘申報適用性覆核',
                period.id, period.undistributed_earnings_due_on, NULL::DATE,
                'review', 'undistributed:' || period.id
            FROM taiwan_fiscal_periods AS period
            WHERE period.book_id = b AND period.undistributed_earnings_due_on IS NOT NULL
              AND period.undistributed_earnings_due_on BETWEEN start_date::DATE AND end_date::DATE
        )
        SELECT
            calendar.seq::BIGINT,
            calendar.key,
	    njord.report_payload(
		'account',
		NULL,
		jsonb_build_array(
		    njord.report_text_cell('obligation', calendar.obligation),
		    njord.report_text_cell('period', calendar.period_label),
		    njord.report_text_cell('due', calendar.due_on::VARCHAR),
		    njord.report_text_cell('completed', calendar.completed_on::VARCHAR),
		    njord.report_text_cell('status',
			CASE calendar.status
                            WHEN 'open' THEN '開啟'
                            WHEN 'prepared' THEN '已編製'
                            WHEN 'filed' THEN '已申報'
                            WHEN 'closed' THEN '已結案'
                            WHEN 'review' THEN '待覆核'
                            ELSE calendar.status
                        END)
                )
            )
        FROM calendar;
    ELSIF requested_report = 'taiwan-trade-aging' THEN
        RETURN QUERY
        WITH aging AS (
            SELECT
                invoice.id,
                invoice.direction,
                party.name AS party_name,
                invoice.invoice_number,
                invoice.due_on,
                abs(invoice_posting.amount)::NUMERIC AS gross,
                COALESCE(sum(allocation.amount)
                    FILTER (WHERE payment_xaction.xid IS NOT NULL), 0)::NUMERIC AS allocated,
                (abs(invoice_posting.amount) - COALESCE(sum(allocation.amount)
                    FILTER (WHERE payment_xaction.xid IS NOT NULL), 0))::NUMERIC
                    AS outstanding
            FROM trade_invoices AS invoice
            JOIN trade_parties AS party
              ON party.book_id = invoice.book_id AND party.id = invoice.party_id
            JOIN report_postings AS invoice_posting
              ON invoice_posting.book_id = invoice.book_id
             AND invoice_posting.xid = invoice.xid
             AND invoice_posting.account_id = invoice.control_acct
            LEFT JOIN trade_invoice_allocations AS allocation
              ON allocation.book_id = invoice.book_id
             AND allocation.invoice_id = invoice.id
             AND allocation.control_acct = invoice.control_acct
            LEFT JOIN xactions AS payment_xaction
              ON payment_xaction.book_id = allocation.book_id
             AND payment_xaction.xid = allocation.payment_xid
             AND payment_xaction.date <= as_of_date
            WHERE invoice.book_id = b
              AND invoice_posting.transaction_date <= as_of_date
            GROUP BY invoice.id, invoice.direction, party.name,
                     invoice.invoice_number, invoice.due_on, invoice_posting.amount
            HAVING abs(invoice_posting.amount) - COALESCE(sum(allocation.amount)
                FILTER (WHERE payment_xaction.xid IS NOT NULL), 0) > 0
        )
        SELECT
            row_number() OVER (
                ORDER BY aging.direction, aging.due_on, aging.party_name, aging.id
            )::BIGINT,
            aging.id,
	    njord.report_payload(
		'account',
		NULL,
		jsonb_build_array(
		    njord.report_text_cell('direction',
			CASE aging.direction
                            WHEN 'receivable' THEN '應收'
                            WHEN 'payable' THEN '應付'
                            ELSE aging.direction
                        END),
		    njord.report_text_cell('party', aging.party_name),
		    njord.report_text_cell('invoice', aging.invoice_number),
		    njord.report_text_cell('due', aging.due_on::VARCHAR),
		    njord.report_number_cell('gross', aging.gross),
		    njord.report_number_cell('paid', aging.allocated),
		    njord.report_number_cell('outstanding', aging.outstanding),
		    njord.report_text_cell('age',
			CASE WHEN as_of_date::DATE <= aging.due_on THEN '未逾期'
                             ELSE '逾期 ' || (as_of_date::DATE - aging.due_on)::VARCHAR || ' 天' END)
                )
            )
        FROM aging;
    ELSIF requested_report = 'taiwan-inventory-rollforward' THEN
        RETURN QUERY
        WITH movement AS (
            SELECT
                item.id,
                sum(CASE WHEN mv.movement_date < start_date::DATE
                    THEN kind.quantity_direction * mv.quantity ELSE 0 END)::NUMERIC
                    AS opening_qty,
                sum(CASE WHEN mv.movement_date BETWEEN start_date::DATE AND end_date::DATE
                              AND kind.quantity_direction = 1
                    THEN mv.quantity ELSE 0 END)::NUMERIC AS receipts,
                sum(CASE WHEN mv.movement_date BETWEEN start_date::DATE AND end_date::DATE
                              AND kind.quantity_direction = -1
                    THEN mv.quantity ELSE 0 END)::NUMERIC AS issues
            FROM taiwan_inventory_items AS item
            LEFT JOIN taiwan_inventory_movements AS mv
              ON mv.book_id = item.book_id AND mv.item_id = item.id
             AND mv.movement_date <= end_date::DATE
            LEFT JOIN taiwan_inventory_movement_kinds AS kind
              ON kind.id = mv.movement_kind
            WHERE item.book_id = b
            GROUP BY item.id
        ),
        valued AS (
            SELECT
                item.id, item.name, item.item_kind, kind.label AS kind_label,
                item.unit, item.inventory_acct,
                COALESCE(movement.opening_qty, 0)::NUMERIC AS opening_qty,
                COALESCE(movement.receipts, 0)::NUMERIC AS receipts,
                COALESCE(movement.issues, 0)::NUMERIC AS issues,
                COALESCE((
                    SELECT sum(bits.amt)
                    FROM xaction_bits AS bits
                    JOIN xactions
                      ON xactions.book_id = bits.book_id AND xactions.xid = bits.xid
                    WHERE bits.book_id = item.book_id
                      AND bits.acct = item.inventory_acct
                      AND xactions.date <= end_date
                ), 0)::NUMERIC AS closing_value
            FROM taiwan_inventory_items AS item
            JOIN taiwan_inventory_item_kinds AS kind ON kind.id = item.item_kind
            LEFT JOIN movement ON movement.id = item.id
            WHERE item.book_id = b
        )
        SELECT
            row_number() OVER (ORDER BY item_kind, name, id)::BIGINT,
            id,
	    njord.report_payload(
		'account',
		inventory_acct,
		jsonb_build_array(
		    njord.report_text_cell('item', name),
		    njord.report_text_cell('kind', kind_label),
		    njord.report_text_cell('unit', unit),
		    njord.report_number_cell('opening_qty', opening_qty),
		    njord.report_number_cell('receipts', receipts),
		    njord.report_number_cell('issues', issues),
		    njord.report_number_cell('closing_qty', opening_qty + receipts - issues),
		    njord.report_number_cell('closing_value', closing_value)
		)
	    )
        FROM valued;
    ELSIF requested_report = 'taiwan-direct-material-usage' THEN
        RETURN QUERY
        WITH usage AS (
            SELECT
                run.id AS run_id,
                product.name AS product_name,
                material.id AS material_id,
                material.name AS material_name,
                material.inventory_acct,
                (run.good_quantity / bom.output_quantity
                    * line.quantity * (1 + line.expected_scrap_percent))::NUMERIC
                    AS expected_quantity,
                COALESCE(sum(movement.quantity), 0)::NUMERIC AS actual_quantity,
                COALESCE(sum(abs(bits.amt)), 0)::NUMERIC AS actual_cost
            FROM taiwan_production_runs AS run
            JOIN taiwan_inventory_items AS product
              ON product.book_id = run.book_id AND product.id = run.product_item_id
            JOIN taiwan_boms AS bom
              ON bom.book_id = run.book_id AND bom.id = run.bom_id
            JOIN taiwan_bom_lines AS line
              ON line.book_id = bom.book_id AND line.bom_id = bom.id
            JOIN taiwan_inventory_items AS material
              ON material.book_id = line.book_id AND material.id = line.material_item_id
            LEFT JOIN taiwan_inventory_movements AS movement
              ON movement.book_id = run.book_id
             AND movement.production_run_id = run.id
             AND movement.item_id = material.id
             AND movement.movement_kind = 'production_issue'
            LEFT JOIN xaction_bits AS bits
              ON bits.book_id = movement.book_id
             AND bits.xid = movement.xid AND bits.acct = material.inventory_acct
            WHERE run.book_id = b
              AND run.started_at BETWEEN start_date AND end_date
            GROUP BY run.id, product.name, material.id, material.name,
                     material.inventory_acct, run.good_quantity,
                     bom.output_quantity, line.quantity,
                     line.expected_scrap_percent
        )
        SELECT
            row_number() OVER (ORDER BY run_id, material_name, material_id)::BIGINT,
            (run_id || ':' || material_id)::VARCHAR,
	    njord.report_payload(
		'account',
		inventory_acct,
		jsonb_build_array(
		    njord.report_text_cell('run', run_id),
		    njord.report_text_cell('product', product_name),
		    njord.report_text_cell('material', material_name),
		    njord.report_number_cell('expected', expected_quantity),
		    njord.report_number_cell('actual', actual_quantity),
		    njord.report_number_cell('variance', actual_quantity - expected_quantity),
		    njord.report_number_cell('cost', actual_cost)
		)
	    )
        FROM usage;
    ELSIF requested_report = 'taiwan-production-cost' THEN
        RETURN QUERY
        WITH run_costs AS (
            SELECT
                run.id,
                product.name AS product_name,
                run.good_quantity,
                COALESCE(sum(abs(bits.amt)) FILTER (
                    WHERE mapping.cost_category = 'direct_material'
                ), 0)::NUMERIC AS material_cost,
                COALESCE(sum(abs(bits.amt)) FILTER (
                    WHERE mapping.cost_category = 'direct_labour'
                ), 0)::NUMERIC AS labour_cost,
                COALESCE(sum(abs(bits.amt)) FILTER (
                    WHERE mapping.cost_category = 'manufacturing_overhead'
                ), 0)::NUMERIC AS overhead_cost,
                COALESCE(sum(abs(bits.amt)) FILTER (
                    WHERE mapping.cost_category = 'finished_goods'
                      AND linked.transaction_role = 'completion'
                ), 0)::NUMERIC AS finished_cost
            FROM taiwan_production_runs AS run
            JOIN taiwan_inventory_items AS product
              ON product.book_id = run.book_id AND product.id = run.product_item_id
            LEFT JOIN taiwan_production_run_transactions AS linked
              ON linked.book_id = run.book_id AND linked.production_run_id = run.id
            LEFT JOIN xaction_bits AS bits
              ON bits.book_id = linked.book_id AND bits.xid = linked.xid
            LEFT JOIN taiwan_manufacturing_account_mappings AS mapping
              ON mapping.book_id = bits.book_id AND mapping.acct = bits.acct
            WHERE run.book_id = b
              AND run.started_at BETWEEN start_date AND end_date
            GROUP BY run.id, product.name, run.good_quantity
        )
        SELECT
            row_number() OVER (ORDER BY id)::BIGINT,
            id,
	    njord.report_payload(
		'account',
		NULL,
		jsonb_build_array(
		    njord.report_text_cell('run', id),
		    njord.report_text_cell('product', product_name),
		    njord.report_number_cell('material', material_cost),
		    njord.report_number_cell('labour', labour_cost),
		    njord.report_number_cell('overhead', overhead_cost),
		    njord.report_number_cell('finished_cost', finished_cost),
		    njord.report_number_cell('good_qty', good_quantity),
		    njord.report_number_cell('unit_cost',
			CASE WHEN good_quantity = 0 THEN NULL
                             ELSE finished_cost / good_quantity END)
                )
            )
        FROM run_costs;
    ELSIF requested_report = 'taiwan-production-yield' THEN
        RETURN QUERY
        SELECT
            row_number() OVER (ORDER BY run.started_at, run.id)::BIGINT,
            run.id,
	    njord.report_payload(
		'account',
		NULL,
		jsonb_build_array(
		    njord.report_text_cell('date', run.completed_at::DATE::VARCHAR),
		    njord.report_text_cell('run', run.id),
		    njord.report_text_cell('product', product.name),
		    njord.report_text_cell('machine', machine.name),
		    njord.report_text_cell('mould', mould.name),
		    njord.report_number_cell('planned', run.planned_quantity),
		    njord.report_number_cell('good', run.good_quantity),
		    njord.report_number_cell('reject', run.reject_quantity),
		    njord.report_number_cell('yield',
			CASE WHEN run.good_quantity + run.reject_quantity = 0 THEN NULL
                             ELSE run.good_quantity
                                / (run.good_quantity + run.reject_quantity) END)
                )
            )
        FROM taiwan_production_runs AS run
        JOIN taiwan_inventory_items AS product
          ON product.book_id = run.book_id AND product.id = run.product_item_id
        LEFT JOIN taiwan_equipment_assets AS machine
          ON machine.book_id = run.book_id AND machine.id = run.machine_id
        LEFT JOIN taiwan_equipment_assets AS mould
          ON mould.book_id = run.book_id AND mould.id = run.mould_id
        WHERE run.book_id = b
          AND run.started_at BETWEEN start_date AND end_date;
    ELSIF requested_report = 'taiwan-product-margin' THEN
        RETURN QUERY
        WITH products AS (
            SELECT * FROM taiwan_inventory_items
            WHERE book_id = b AND item_kind = 'finished_good'
        ),
        sales AS (
            SELECT
                invoice.item_id,
                sum(abs(net_bits.amt))::NUMERIC AS revenue
            FROM taiwan_uniform_invoices AS invoice
            JOIN xaction_bits AS net_bits
              ON net_bits.book_id = invoice.book_id
             AND net_bits.xid = invoice.xid AND net_bits.acct = invoice.net_acct
            WHERE invoice.book_id = b
              AND invoice.direction = 'sale'
              AND invoice.item_id IS NOT NULL
              AND invoice.invoice_date BETWEEN start_date::DATE AND end_date::DATE
            GROUP BY invoice.item_id
        ),
        dispatch AS (
            SELECT
                movement.item_id,
                sum(movement.quantity)::NUMERIC AS units,
                sum(abs(bits.amt))::NUMERIC AS cogs
            FROM taiwan_inventory_movements AS movement
            JOIN taiwan_inventory_items AS item
              ON item.book_id = movement.book_id AND item.id = movement.item_id
            JOIN xaction_bits AS bits
              ON bits.book_id = movement.book_id
             AND bits.xid = movement.xid AND bits.acct = item.inventory_acct
            WHERE movement.book_id = b
              AND movement.movement_kind = 'sale'
              AND movement.movement_date BETWEEN start_date::DATE AND end_date::DATE
            GROUP BY movement.item_id
        )
        SELECT
            row_number() OVER (ORDER BY products.name, products.id)::BIGINT,
            products.id,
	    njord.report_payload(
		'account',
		products.inventory_acct,
		jsonb_build_array(
		    njord.report_text_cell('product', products.name),
		    njord.report_number_cell('units', COALESCE(dispatch.units, 0)),
		    njord.report_number_cell('revenue', COALESCE(sales.revenue, 0)),
		    njord.report_number_cell('cogs', COALESCE(dispatch.cogs, 0)),
		    njord.report_number_cell('margin',
			COALESCE(sales.revenue, 0) - COALESCE(dispatch.cogs, 0)),
		    njord.report_number_cell('margin_percent',
			CASE WHEN COALESCE(sales.revenue, 0) = 0 THEN NULL
                             ELSE (COALESCE(sales.revenue, 0) - COALESCE(dispatch.cogs, 0))
                                  / sales.revenue END)
                )
            )
        FROM products
        LEFT JOIN sales ON sales.item_id = products.id
        LEFT JOIN dispatch ON dispatch.item_id = products.id;
    ELSIF requested_report = 'taiwan-equipment-register' THEN
        RETURN QUERY
        WITH balances AS (
            SELECT
                equipment.*,
                kind.label AS kind_label,
                COALESCE((
                    SELECT sum(bits.amt)
                    FROM xaction_bits AS bits
                    JOIN xactions
                      ON xactions.book_id = bits.book_id AND xactions.xid = bits.xid
                    WHERE bits.book_id = equipment.book_id
                      AND bits.acct = equipment.asset_acct
                      AND xactions.date <= as_of_date
                ), 0)::NUMERIC AS cost,
                COALESCE((
                    SELECT sum(bits.amt)
                    FROM xaction_bits AS bits
                    JOIN xactions
                      ON xactions.book_id = bits.book_id AND xactions.xid = bits.xid
                    WHERE bits.book_id = equipment.book_id
                      AND bits.acct = equipment.accumulated_depreciation_acct
                      AND xactions.date <= as_of_date
                ), 0)::NUMERIC AS accumulated_depreciation
            FROM taiwan_equipment_assets AS equipment
            JOIN taiwan_equipment_kinds AS kind ON kind.id = equipment.equipment_kind
            WHERE equipment.book_id = b
        )
        SELECT
            row_number() OVER (ORDER BY kind_label, name, id)::BIGINT,
            id,
	    njord.report_payload(
		'account',
		asset_acct,
		jsonb_build_array(
		    njord.report_text_cell('equipment', name),
		    njord.report_text_cell('kind', kind_label),
		    njord.report_text_cell('in_service', in_service_on::VARCHAR),
		    njord.report_number_cell('cost', cost),
		    njord.report_number_cell('depreciation', abs(accumulated_depreciation)),
		    njord.report_number_cell('net_book_value', cost + accumulated_depreciation),
		    njord.report_text_cell('life',
			CASE WHEN useful_life_months IS NULL THEN NULL
			     ELSE useful_life_months::VARCHAR || ' 個月' END),
		    njord.report_text_cell('location', location)
                )
            )
        FROM balances;
    END IF;
END;
$$;

COMMENT ON FUNCTION taiwan_report_rows(
    VARCHAR, VARCHAR, TIMESTAMP, TIMESTAMP, TIMESTAMP
) IS
    'Normalized Taiwan bookkeeping and injection-moulding report rows for the generic SQL-defined report page.';

-- Taiwan settings are offered only to TWD books. SQL owns that eligibility,
-- profile readiness, and the optional manufacturing seam.
CREATE OR REPLACE FUNCTION api.taiwan_book_components(p_book_id VARCHAR)
RETURNS SETOF api.page_component
LANGUAGE SQL
STABLE
AS $$
    WITH configuration AS (
        SELECT
            books.id AS book_id,
            books.name AS book_name,
            profile.book_id IS NOT NULL AS profile_enabled,
            profile.legal_name,
            profile.unified_business_number,
            profile.legal_form,
            profile.business_tax_frequency,
            profile.uses_uniform_invoices,
            profile.established_on,
            profile.responsible_person,
            profile.registered_address,
            profile.tax_registration_notes,
            profile.notes,
            manufacturing.book_id IS NOT NULL AS manufacturing_enabled,
            (SELECT count(*)::INTEGER FROM taiwan_inventory_items AS item
             WHERE item.book_id = books.id) AS inventory_item_count,
            EXISTS (
                SELECT 1 FROM public.taiwan_fiscal_periods AS period
                WHERE period.book_id = books.id
            ) AS has_period
        FROM books
        JOIN book_entity_types AS entity_types
          ON entity_types.id = books.entity_type
        LEFT JOIN taiwan_business_profiles AS profile ON profile.book_id = books.id
        LEFT JOIN taiwan_manufacturing_profiles AS manufacturing
          ON manufacturing.book_id = books.id
        WHERE books.id = p_book_id
          AND entity_types.allows_business_packs
          AND books.reporting_asset = 'TWD'
    )
    SELECT
        'taiwan_business_profile'::VARCHAR,
        13500::BIGINT,
        configuration.book_id,
        jsonb_build_object(
            'enabled', configuration.profile_enabled,
            'legal_name', COALESCE(configuration.legal_name, configuration.book_name),
            'unified_business_number', COALESCE(configuration.unified_business_number, ''),
            'legal_form', COALESCE(configuration.legal_form, 'limited_company'),
            'business_tax_frequency', COALESCE(
                configuration.business_tax_frequency, 'bimonthly'
            ),
            'uses_uniform_invoices', COALESCE(configuration.uses_uniform_invoices, TRUE),
            'established_on', configuration.established_on,
            'responsible_person', configuration.responsible_person,
            'registered_address', configuration.registered_address,
            'tax_registration_notes', configuration.tax_registration_notes,
            'manufacturing_enabled', configuration.manufacturing_enabled,
            'inventory_item_count', configuration.inventory_item_count,
            'notes', configuration.notes
        )
    FROM configuration
UNION ALL
    SELECT
        'configuration_check'::VARCHAR,
        13600::BIGINT,
        'taiwan_profile'::VARCHAR,
        njord.configuration_check_payload(
            'taiwan_profile',
            'Taiwan business profile',
            configuration.profile_enabled,
            CASE WHEN configuration.profile_enabled THEN NULL
                ELSE 'Save the Taiwan business settings to enable its working papers.' END
        )
    FROM configuration
UNION ALL
    SELECT
        'configuration_check'::VARCHAR,
        13601::BIGINT,
        'taiwan_period'::VARCHAR,
        njord.configuration_check_payload(
            'taiwan_period',
            'Fiscal period',
            configuration.profile_enabled AND configuration.has_period,
            CASE
                WHEN NOT configuration.profile_enabled THEN 'Save the business profile first.'
                WHEN NOT configuration.has_period THEN 'Add one fiscal period.'
                ELSE NULL
            END
        )
    FROM configuration
UNION ALL
    SELECT
        'configuration_check'::VARCHAR,
        13602::BIGINT,
        'taiwan_manufacturing'::VARCHAR,
        njord.configuration_check_payload(
            'taiwan_manufacturing',
            'Injection-moulding manufacturing extension',
            configuration.manufacturing_enabled
                AND configuration.inventory_item_count > 0,
            CASE
                WHEN NOT configuration.manufacturing_enabled THEN
                    'Optional; enable it for production, stock, BOM, machine, and mould schedules.'
                WHEN configuration.inventory_item_count = 0 THEN
                    'Record inventory items before relying on manufacturing schedules.'
                ELSE NULL
            END
        )
    FROM configuration
UNION ALL
    SELECT
        'taiwan_legal_form_option'::VARCHAR,
        13700 + row_number() OVER (ORDER BY form.label, form.id),
        form.id,
        njord.labelled_option_payload(form.id, form.label)
    FROM taiwan_legal_forms AS form
    WHERE EXISTS (SELECT 1 FROM configuration)
UNION ALL
    SELECT
        'taiwan_tax_frequency_option'::VARCHAR,
        13800 + row_number() OVER (ORDER BY frequency.label, frequency.id),
        frequency.id,
        njord.labelled_option_payload(frequency.id, frequency.label)
    FROM taiwan_business_tax_frequencies AS frequency
    WHERE EXISTS (SELECT 1 FROM configuration)
UNION ALL
    SELECT
        'taiwan_period_status_option'::VARCHAR,
        13900 + row_number() OVER (ORDER BY status.label, status.id),
        status.id,
        njord.labelled_option_payload(status.id, status.label)
    FROM taiwan_period_statuses AS status
    WHERE EXISTS (SELECT 1 FROM configuration)
UNION ALL
    SELECT
        'taiwan_fiscal_period'::VARCHAR,
        14000 + row_number() OVER (ORDER BY period.period_start DESC, period.id),
        period.id,
        jsonb_build_object(
            'id', period.id,
            'period_start', period.period_start,
            'period_end', period.period_end,
            'status', period.status,
            'annual_income_tax_due_on', period.annual_income_tax_due_on,
            'provisional_income_tax_due_on', period.provisional_income_tax_due_on,
            'undistributed_earnings_due_on', period.undistributed_earnings_due_on,
            'notes', period.notes
        )
    FROM taiwan_fiscal_periods AS period
    WHERE period.book_id = p_book_id;
$$;

-- Configure a compact Taiwan bookkeeping profile and an explicit fiscal
-- period. The optional manufacturing marker unlocks production schedules; it
-- does not invent inventory items, BOMs, tax obligations, or return figures.
CREATE OR REPLACE FUNCTION api.configure_taiwan_business(
    p_book_id VARCHAR,
    p_legal_name VARCHAR,
    p_unified_business_number VARCHAR,
    p_legal_form VARCHAR,
    p_business_tax_frequency VARCHAR,
    p_period_id VARCHAR,
    p_period_start DATE,
    p_period_end DATE,
    p_uses_uniform_invoices BOOLEAN DEFAULT TRUE,
    p_enable_manufacturing BOOLEAN DEFAULT FALSE,
    p_established_on DATE DEFAULT NULL,
    p_responsible_person VARCHAR DEFAULT NULL,
    p_registered_address VARCHAR DEFAULT NULL,
    p_tax_registration_notes VARCHAR DEFAULT NULL,
    p_notes VARCHAR DEFAULT NULL,
    p_period_status VARCHAR DEFAULT 'open',
    p_annual_income_tax_due_on DATE DEFAULT NULL,
    p_provisional_income_tax_due_on DATE DEFAULT NULL,
    p_undistributed_earnings_due_on DATE DEFAULT NULL,
    p_period_notes VARCHAR DEFAULT NULL
)
RETURNS SETOF api.page_component
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    normalized_legal_name VARCHAR := NULLIF(btrim(p_legal_name), '');
    normalized_ubn VARCHAR := NULLIF(btrim(p_unified_business_number), '');
    normalized_legal_form VARCHAR := NULLIF(btrim(p_legal_form), '');
    normalized_frequency VARCHAR := NULLIF(btrim(p_business_tax_frequency), '');
    normalized_period_id VARCHAR := NULLIF(btrim(p_period_id), '');
    normalized_period_status VARCHAR := COALESCE(
        NULLIF(btrim(p_period_status), ''), 'open'
    );
    reporting_asset VARCHAR;
BEGIN
    reporting_asset := njord.lock_book_reporting_asset(p_book_id);
    IF reporting_asset <> 'TWD' THEN
        RAISE EXCEPTION 'Taiwan business configuration requires a TWD book'
            USING ERRCODE = 'P0001', DETAIL = 'TAIWAN_BUSINESS_REQUIRES_TWD';
    END IF;
    UPDATE public.books
    SET entity_type = CASE
	WHEN normalized_legal_form = 'sole_proprietorship' THEN 'sole_trader'
	WHEN normalized_legal_form = 'partnership' THEN 'partnership'
	ELSE 'company'
    END
    WHERE id = p_book_id AND entity_type = 'household';
    IF normalized_legal_name IS NULL THEN
        RAISE EXCEPTION 'business legal name is required'
            USING ERRCODE = 'P0001', DETAIL = 'BUSINESS_LEGAL_NAME_REQUIRED';
    END IF;
    IF normalized_ubn IS NULL OR normalized_ubn !~ '^[0-9]{8}$' THEN
        RAISE EXCEPTION 'Unified Business Number must contain eight digits'
            USING ERRCODE = 'P0001', DETAIL = 'TAIWAN_UBN_INVALID';
    END IF;
    IF normalized_legal_form IS NULL OR NOT EXISTS (
        SELECT 1 FROM taiwan_legal_forms WHERE id = normalized_legal_form
    ) THEN
        RAISE EXCEPTION 'Taiwan legal form does not exist'
            USING ERRCODE = 'P0001', DETAIL = 'TAIWAN_LEGAL_FORM_NOT_FOUND';
    END IF;
    IF normalized_frequency IS NULL OR NOT EXISTS (
        SELECT 1 FROM taiwan_business_tax_frequencies
        WHERE id = normalized_frequency
    ) THEN
        RAISE EXCEPTION 'business-tax frequency does not exist'
            USING ERRCODE = 'P0001', DETAIL = 'TAIWAN_TAX_FREQUENCY_NOT_FOUND';
    END IF;
    IF normalized_period_id IS NULL THEN
        RAISE EXCEPTION 'fiscal period id is required'
            USING ERRCODE = 'P0001', DETAIL = 'FISCAL_PERIOD_ID_REQUIRED';
    END IF;
    IF p_period_start IS NULL OR p_period_end IS NULL THEN
        RAISE EXCEPTION 'fiscal period dates are required'
            USING ERRCODE = 'P0001', DETAIL = 'FISCAL_PERIOD_DATES_REQUIRED';
    END IF;
    IF p_period_start > p_period_end THEN
        RAISE EXCEPTION 'fiscal period starts after it ends'
            USING ERRCODE = 'P0001', DETAIL = 'INVALID_FISCAL_PERIOD';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM taiwan_period_statuses WHERE id = normalized_period_status
    ) THEN
        RAISE EXCEPTION 'fiscal period status does not exist'
            USING ERRCODE = 'P0001', DETAIL = 'PERIOD_STATUS_NOT_FOUND';
    END IF;

    PERFORM njord.ensure_standard_accounts(p_book_id, FALSE);

    INSERT INTO taiwan_business_profiles (
        book_id, legal_name, unified_business_number, legal_form,
        business_tax_frequency, uses_uniform_invoices,
        established_on, responsible_person, registered_address,
        tax_registration_notes, notes
    ) VALUES (
        p_book_id, normalized_legal_name, normalized_ubn,
        normalized_legal_form, normalized_frequency,
        COALESCE(p_uses_uniform_invoices, TRUE), p_established_on,
        NULLIF(btrim(p_responsible_person), ''),
        NULLIF(btrim(p_registered_address), ''),
        NULLIF(btrim(p_tax_registration_notes), ''),
        NULLIF(btrim(p_notes), '')
    )
    ON CONFLICT (book_id) DO UPDATE SET
        legal_name = EXCLUDED.legal_name,
        unified_business_number = EXCLUDED.unified_business_number,
        legal_form = EXCLUDED.legal_form,
        business_tax_frequency = EXCLUDED.business_tax_frequency,
        uses_uniform_invoices = EXCLUDED.uses_uniform_invoices,
        established_on = EXCLUDED.established_on,
        responsible_person = EXCLUDED.responsible_person,
        registered_address = EXCLUDED.registered_address,
        tax_registration_notes = EXCLUDED.tax_registration_notes,
        notes = EXCLUDED.notes;

    INSERT INTO taiwan_fiscal_periods (
        book_id, id, period_start, period_end, status,
        annual_income_tax_due_on, provisional_income_tax_due_on,
        undistributed_earnings_due_on, notes
    ) VALUES (
        p_book_id, normalized_period_id, p_period_start, p_period_end,
        normalized_period_status,
        p_annual_income_tax_due_on, p_provisional_income_tax_due_on,
        p_undistributed_earnings_due_on, NULLIF(btrim(p_period_notes), '')
    )
    ON CONFLICT (book_id, id) DO UPDATE SET
        period_start = EXCLUDED.period_start,
        period_end = EXCLUDED.period_end,
        status = EXCLUDED.status,
        annual_income_tax_due_on = EXCLUDED.annual_income_tax_due_on,
        provisional_income_tax_due_on = EXCLUDED.provisional_income_tax_due_on,
        undistributed_earnings_due_on = EXCLUDED.undistributed_earnings_due_on,
        notes = EXCLUDED.notes;

    IF COALESCE(p_enable_manufacturing, FALSE) THEN
        INSERT INTO taiwan_manufacturing_profiles (book_id)
        VALUES (p_book_id)
        ON CONFLICT (book_id) DO NOTHING;
    ELSE
        BEGIN
            DELETE FROM taiwan_manufacturing_profiles
            WHERE book_id = p_book_id;
        EXCEPTION WHEN foreign_key_violation THEN
            RAISE EXCEPTION 'manufacturing records must be removed before disabling the extension'
                USING ERRCODE = 'P0001',
                      DETAIL = 'TAIWAN_MANUFACTURING_EXTENSION_HAS_DATA';
        END;
    END IF;

    RETURN QUERY SELECT * FROM api.book_page(p_book_id);
END;
$$;
