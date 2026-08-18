-- SQL-owned application vocabulary. This file is loaded in both the control
-- database and every Book database so either canonical shell can resolve the
-- same stable semantic keys without an Elm string table.

DROP SCHEMA IF EXISTS presentation CASCADE;
CREATE SCHEMA presentation;

-- Every page RPC returns this stable relational envelope. Keeping the shape
-- named lets page functions share one database-owned interface while payloads
-- remain component-specific.
CREATE TYPE api.page_component AS (
    component VARCHAR,
    row_order BIGINT,
    row_key VARCHAR,
    payload JSONB
);

CREATE TABLE presentation.locales (
    locale VARCHAR PRIMARY KEY,
    fallback_locale VARCHAR REFERENCES presentation.locales(locale),
    enabled BOOLEAN NOT NULL DEFAULT FALSE,
    complete BOOLEAN NOT NULL DEFAULT FALSE,
    flag VARCHAR NOT NULL
);

INSERT INTO presentation.locales (
    locale, fallback_locale, enabled, complete, flag
) VALUES
    ('en-GB', NULL, TRUE, TRUE, '🇬🇧'),
    ('es-PA', 'en-GB', FALSE, FALSE, '🇵🇦'),
    ('zh-TW', 'en-GB', FALSE, FALSE, '🇹🇼');

CREATE TABLE presentation.messages (
    locale VARCHAR NOT NULL REFERENCES presentation.locales(locale)
        ON DELETE CASCADE,
    semantic_key VARCHAR NOT NULL,
    display_text TEXT NOT NULL,
    PRIMARY KEY (locale, semantic_key),
    CHECK (semantic_key ~ '^[A-Za-z][A-Za-z0-9_.-]*$'),
    CHECK (display_text <> '')
);

-- Semantic keys are deliberately independent of page layout. A renderer asks
-- for (for example) field.transaction.date wherever that concept appears.
WITH vocabulary(semantic_key, "en-GB", "es-PA", "zh-TW") AS (
    -- Keeping each concept on one row makes translation drift and omissions
    -- visible in review instead of hiding them in three distant dictionaries.
    VALUES
        ('app.name', 'Njord', 'Njord', 'Njord'),
        ('language.choose', 'Choose display language', 'Elegir idioma de visualización', '選擇顯示語言'),
        ('language.en-GB', 'English', 'Inglés', '英文'),
        ('language.es-PA', 'Spanish', 'Español', '西班牙文'),
        ('language.zh-TW', 'Traditional Chinese', 'Chino tradicional', '繁體中文'),
        ('entity.household', 'Household or individual', 'Hogar o persona', '家庭或個人'),
        ('entity.sole_trader', 'Sole trader', 'Empresario individual', '獨資經營者'),
        ('entity.partnership', 'Partnership', 'Sociedad', '合夥'),
        ('entity.company', 'Company', 'Empresa', '公司'),
        ('entity.charity', 'Charity or non-profit', 'Organización benéfica o sin fines de lucro', '慈善或非營利組織'),
        ('entity.trust', 'Trust', 'Fideicomiso', '信託'),
        ('entity.other_organisation', 'Other organisation', 'Otra organización', '其他組織'),
        ('nav.primary', 'Primary', 'Principal', '主要導覽'),
        ('nav.admin', 'Admin', 'Administración', '管理'),
        ('nav.books', 'Books', 'Libros', '帳簿'),
        ('nav.book', 'Book', 'Libro', '帳簿'),
        ('nav.accounts', 'Accounts', 'Cuentas', '科目'),
        ('nav.journal', 'Journal', 'Diario', '日記帳'),
        ('nav.reconciliation', 'Reconciliation', 'Conciliación', '對帳'),
        ('nav.reports', 'Reports', 'Informes', '報表'),
        ('nav.help', 'Help', 'Ayuda', '說明'),
        ('option.book.select', 'Select book', 'Seleccionar libro', '選擇帳簿'),
        ('option.book.add', 'Add book…', 'Agregar libro…', '新增帳簿…'),
        ('option.account.select', 'Select account', 'Seleccionar cuenta', '選擇科目'),
        ('option.account.add', 'Add account…', 'Agregar cuenta…', '新增科目…'),
        ('option.account.all', 'All accounts', 'Todas las cuentas', '所有科目'),
        ('option.account.vat-auto', 'Create VAT Control automatically', 'Crear automáticamente la cuenta de control de ITBMS', '自動建立營業稅控制科目'),
        ('option.transaction.split', '-- Split Transaction --', '-- Transacción dividida --', '-- 分錄拆分 --'),
        ('page.start.title', 'Start accounting', 'Comenzar la contabilidad', '開始記帳'),
        ('page.start.intro', 'Create a book to begin.', 'Cree un libro para comenzar.', '請建立帳簿以開始。'),
        ('page.books.title', 'Books', 'Libros', '帳簿'),
        ('page.books.intro', 'Choose a book to manage it, or open it in another browser tab.', 'Elija un libro para administrarlo o ábralo en otra pestaña del navegador.', '選擇帳簿以進行管理，或在另一個瀏覽器分頁中開啟。'),
        ('page.admin.title', 'Admin', 'Administración', '管理'),
        ('page.admin.intro', 'Manage the people allowed to use this Njord installation.', 'Administre las personas autorizadas para usar esta instalación de Njord.', '管理獲准使用此 Njord 系統的人員。'),
        ('page.admin.empty', 'No users have been admitted.', 'No se ha admitido a ningún usuario.', '尚未允許任何使用者。'),
        ('page.book.title', 'Book', 'Libro', '帳簿'),
        ('page.accounts.title', 'Accounts', 'Cuentas', '科目'),
        ('page.accounts.intro', 'Expand the account tree, or choose a posting account to open its register.', 'Expanda el árbol de cuentas o elija una cuenta de registro para abrir su mayor.', '展開科目樹，或選擇記帳科目以開啟分類帳。'),
        ('page.accounts.empty', 'This book has no accounts.', 'Este libro no tiene cuentas.', '此帳簿尚無科目。'),
        ('page.ledger.title', 'Account ledger', 'Mayor de cuenta', '科目分類帳'),
        ('page.reconciliation.title', 'Reconciliation', 'Conciliación', '對帳'),
        ('page.reconciliation.empty', 'No postings match this account filter.', 'Ningún asiento coincide con este filtro de cuenta.', '沒有符合此科目篩選條件的分錄。'),
        ('page.reconciliation.summary', '{unreconciled} unreconciled of {total} postings', '{unreconciled} sin conciliar de {total} asientos', '共 {total} 筆分錄，其中 {unreconciled} 筆尚未對帳'),
        ('page.reports.title', 'Reports', 'Informes', '報表'),
        ('page.reports.intro', 'Choose a report for the current book.', 'Elija un informe para el libro actual.', '請為目前帳簿選擇報表。'),
        ('page.journal.title', 'General Journal', 'Diario general', '普通日記帳'),
        ('page.report.unavailable', 'Report unavailable', 'Informe no disponible', '報表無法使用'),
        ('page.book.add.title', 'Add book', 'Agregar libro', '新增帳簿'),
        ('page.account.add.title', 'Add account', 'Agregar cuenta', '新增科目'),
        ('section.book.identity', 'Ledger identity', 'Identidad del libro mayor', '帳簿識別'),
        ('section.book.configuration', 'Configuration', 'Configuración', '設定'),
        ('section.book.details', 'Book details', 'Detalles del libro', '帳簿詳細資料'),
        ('section.book.currency', 'Reporting currency', 'Moneda de presentación', '報表幣別'),
        ('section.book.lifecycle', 'Book lifecycle', 'Ciclo de vida del libro', '帳簿生命週期'),
        ('section.book.access', 'Access', 'Acceso', '存取權'),
        ('section.book.access-intro', 'Invite a GitHub user or change who can use this book.', 'Invite a un usuario de GitHub o cambie quién puede usar este libro.', '邀請 GitHub 使用者或變更此帳簿的使用權限。'),
        ('section.admin.users', 'Allowed users', 'Usuarios autorizados', '允許的使用者'),
        ('section.uk-company', 'UK company', 'Empresa del Reino Unido', '英國公司'),
        ('section.panama-business', 'Panama business', 'Empresa de Panamá', '巴拿馬企業'),
        ('section.taiwan-business', 'Taiwan business', 'Empresa de Taiwán', '臺灣企業'),
        ('group.company.identity', 'Company identity', 'Identidad de la empresa', '公司識別'),
        ('group.business.identity', 'Business identity', 'Identidad del negocio', '企業識別'),
        ('group.accounting.scope', 'Accounting scope', 'Alcance contable', '會計範圍'),
        ('group.accounting.period', 'Accounting period', 'Período contable', '會計期間'),
        ('group.fiscal.period', 'Fiscal period', 'Período fiscal', '財政期間'),
        ('group.hmrc-vat', 'HMRC and VAT', 'HMRC e IVA', 'HMRC 與增值稅'),
        ('group.notes', 'Notes', 'Notas', '備註'),
        ('group.notes.additional', 'Additional notes', 'Notas adicionales', '其他備註'),
        ('field.book.id', 'Identifier', 'Identificador', '識別碼'),
        ('field.book.name', 'Book name', 'Nombre del libro', '帳簿名稱'),
        ('field.book.owner-entity', 'Owner or entity', 'Propietario o entidad', '擁有者或實體'),
        ('field.book.current-currency', 'Current reporting currency', 'Moneda de presentación actual', '目前報表幣別'),
        ('field.book.currency', 'Currency', 'Moneda', '幣別'),
        ('field.book.reporting-asset', 'Reporting asset', 'Activo de presentación', '報表資產'),
        ('field.book.currency-effective-date', 'Effective date for an active book', 'Fecha de vigencia para un libro activo', '啟用中帳簿的生效日期'),
        ('field.access.github-login', 'GitHub user', 'Usuario de GitHub', 'GitHub 使用者'),
        ('field.access.level', 'Access', 'Acceso', '存取權'),
        ('column.user', 'User', 'Usuario', '使用者'),
        ('column.database-role', 'PostgreSQL role', 'Rol de PostgreSQL', 'PostgreSQL 角色'),
        ('column.status', 'Status', 'Estado', '狀態'),
        ('column.books', 'Books', 'Libros', '帳簿'),
        ('column.global-admin', 'Global admin', 'Administrador global', '全域管理員'),
        ('column.actions', 'Actions', 'Acciones', '操作'),
        ('access.ro', 'RO', 'RO', 'RO'),
        ('access.rw', 'RW', 'RW', 'RW'),
        ('access.admin', 'Admin', 'Admin', '管理'),
        ('action.access.add', 'Add user', 'Agregar usuario', '新增使用者'),
        ('action.admin.invite-user', 'Invite user', 'Invitar usuario', '邀請使用者'),
        ('action.admin.disable-user', 'Disable', 'Deshabilitar', '停用'),
        ('action.admin.enable-user', 'Enable', 'Habilitar', '啟用'),
        ('action.access.remove', 'Remove', 'Quitar', '移除'),
        ('action.reconcile', 'Reconcile', 'Conciliar', '對帳'),
        ('state.access.active', 'Active', 'Activo', '有效'),
        ('state.access.pending', 'Pending', 'Pendiente', '待接受'),
        ('state.access.direct', 'Direct SQL', 'SQL directo', '直接 SQL'),
        ('state.access.disabled', 'Disabled', 'Deshabilitado', '已停用'),
        ('state.access.expired', 'Expired', 'Vencido', '已過期'),
        ('state.access.revoked', 'Revoked', 'Revocado', '已撤銷'),
        ('field.legal-name', 'Legal name', 'Nombre legal', '法定名稱'),
        ('field.company-number', 'Company number', 'Número de empresa', '公司編號'),
        ('field.legal-form', 'Legal form', 'Forma jurídica', '法律形式'),
        ('field.accounting-framework', 'Accounting framework', 'Marco contable', '會計準則'),
        ('field.incorporation-date', 'Incorporation date', 'Fecha de constitución', '成立日期'),
        ('field.registered-office', 'Registered office', 'Domicilio social', '註冊辦事處'),
        ('field.utr', 'UTR', 'UTR', 'UTR'),
        ('field.vat-registration-number', 'VAT registration number', 'Número de registro de IVA', '增值稅登記號碼'),
        ('field.vat-scheme', 'VAT scheme', 'Régimen de IVA', '增值稅制度'),
        ('field.vat-control-account', 'VAT control account', 'Cuenta de control de IVA', '增值稅控制科目'),
        ('field.period.id', 'Period identifier', 'Identificador del período', '期間識別碼'),
        ('field.period.start', 'Period start', 'Inicio del período', '期間開始'),
        ('field.period.end', 'Period end', 'Fin del período', '期間結束'),
        ('field.period.status', 'Period status', 'Estado del período', '期間狀態'),
        ('field.accounts-due', 'Accounts due', 'Vencimiento de cuentas', '財報到期日'),
        ('field.corporation-tax-due', 'Corporation Tax due', 'Vencimiento del impuesto de sociedades', '公司稅到期日'),
        ('field.accounts-filed', 'Accounts filed', 'Cuentas presentadas', '財報已申報'),
        ('field.ct600-filed', 'CT600 filed', 'CT600 presentado', 'CT600 已申報'),
        ('field.company-notes', 'Company notes', 'Notas de la empresa', '公司備註'),
        ('field.business-notes', 'Business notes', 'Notas del negocio', '企業備註'),
        ('field.period-notes', 'Period notes', 'Notas del período', '期間備註'),
        ('field.ruc', 'RUC', 'RUC', 'RUC'),
        ('field.verification-digit', 'Verification digit', 'Dígito verificador', '驗證碼'),
        ('field.municipality', 'Municipality', 'Municipio', '自治區'),
        ('field.resident-agent', 'Resident agent', 'Agente residente', '常駐代理人'),
        ('field.operations-notice', 'Operations notice', 'Aviso de operación', '營業通知'),
        ('field.registered-address', 'Registered address', 'Dirección registrada', '登記地址'),
        ('field.income-tax-return-due', 'Income-tax return due', 'Vencimiento de la declaración de renta', '所得稅申報到期日'),
        ('field.municipal-return-due', 'Municipal return due', 'Vencimiento de la declaración municipal', '市政申報到期日'),
        ('field.unified-business-number', 'Unified Business Number', 'Número comercial unificado', '統一編號'),
        ('field.established-on', 'Established on', 'Fecha de establecimiento', '設立日期'),
        ('field.responsible-person', 'Responsible person', 'Persona responsable', '負責人'),
        ('field.business-tax-frequency', 'Business-tax filing frequency', 'Frecuencia de declaración del impuesto comercial', '營業稅申報頻率'),
        ('field.tax-registration-notes', 'Tax-registration notes', 'Notas de registro fiscal', '稅籍登記備註'),
        ('field.annual-income-tax-due', 'Annual income-tax due', 'Vencimiento del impuesto anual sobre la renta', '年度所得稅到期日'),
        ('field.provisional-income-tax-due', 'Provisional income-tax due', 'Vencimiento del impuesto provisional sobre la renta', '暫繳所得稅到期日'),
        ('field.undistributed-earnings-due', 'Undistributed-earnings due', 'Vencimiento de utilidades no distribuidas', '未分配盈餘稅到期日'),
        ('field.itbms-registered', 'ITBMS registered', 'Registrado para ITBMS', '已登記 ITBMS'),
        ('field.lodging-activity', 'Records lodging activity', 'Registra actividad de hospedaje', '記錄住宿活動'),
        ('field.residential-property-enabled', 'Enable residential-property records', 'Habilitar registros de propiedad residencial', '啟用住宅物業記錄'),
        ('field.uniform-invoices', 'Uses uniform invoices', 'Usa facturas uniformes', '使用統一發票'),
        ('field.injection-moulding-enabled', 'Enable injection-moulding manufacturing records', 'Habilitar registros de fabricación por moldeo por inyección', '啟用塑膠射出成型製造記錄'),
        ('field.account.name', 'Name', 'Nombre', '名稱'),
        ('field.account.parent', 'Parent account', 'Cuenta superior', '上層科目'),
        ('field.account.class', 'Class', 'Clase', '類別'),
        ('field.account.commodity', 'Commodity', 'Producto', '商品'),
        ('field.account.kind', 'Account kind', 'Tipo de cuenta', '科目種類'),
        ('field.account.placeholder', 'Placeholder (group only; no direct postings)', 'Cuenta de agrupación (sin asientos directos)', '群組科目（不可直接記帳）'),
        ('field.account.pretax', 'Pretax fraction', 'Fracción antes de impuestos', '稅前比例'),
        ('field.account.opening-balance', 'Opening balance (optional)', 'Saldo inicial (opcional)', '期初餘額（選填）'),
        ('field.account.opening-date', 'Opening date', 'Fecha de apertura', '期初日期'),
        ('field.account.filter', 'Account filter', 'Filtro de cuenta', '科目篩選'),
        ('field.transaction.date', 'Date', 'Fecha', '日期'),
        ('field.transaction.description', 'Description', 'Descripción', '說明'),
        ('field.transaction.transfer', 'Transfer', 'Transferencia', '轉帳科目'),
        ('field.transaction.deposit', 'Deposit', 'Depósito', '存入'),
        ('field.transaction.withdrawal', 'Withdrawal', 'Retiro', '支出'),
        ('field.transaction.balance', 'Balance', 'Saldo', '餘額'),
        ('field.transaction.memo', 'Memo', 'Nota', '備註'),
        ('field.transaction.debit', 'Debit', 'Débito', '借方'),
        ('field.transaction.credit', 'Credit', 'Crédito', '貸方'),
        ('field.transaction.reconciled-short', 'R', 'C', '對'),
        ('field.reconciliation.reconciled', 'Reconciled', 'Conciliado', '已對帳'),
        ('state.reconciled-posting', 'Reconciled posting', 'Asiento conciliado', '已對帳分錄'),
        ('state.unreconciled-posting', 'Unreconciled posting', 'Asiento sin conciliar', '未對帳分錄'),
        ('aria.reconciled-posting', 'Reconciled posting for {account} on {date}', 'Asiento conciliado de {account} el {date}', '{account} 在 {date} 的已對帳分錄'),
        ('field.asset', 'Asset', 'Activo', '資產'),
        ('field.report.as-of', 'As of', 'Al', '截至'),
        ('field.report.from', 'From', 'Desde', '自'),
        ('field.report.to', 'To', 'Hasta', '至'),
        ('column.account', 'Account', 'Cuenta', '科目'),
        ('column.commodity', 'Commodity', 'Producto', '商品'),
        ('column.native-balance', 'Native balance', 'Saldo original', '原幣餘額'),
        ('column.reporting-market-value', 'Reporting / market value', 'Valor de presentación / mercado', '報表／市場價值'),
        ('column.postings', 'Postings', 'Asientos', '分錄'),
        ('column.unreconciled', 'Unreconciled', 'Sin conciliar', '未對帳'),
        ('action.book.add', 'Add book', 'Agregar libro', '新增帳簿'),
        ('action.book.save', 'Save book details', 'Guardar detalles del libro', '儲存帳簿詳細資料'),
        ('action.book.currency-update', 'Update reporting currency', 'Actualizar moneda de presentación', '更新報表幣別'),
        ('action.book.archive', 'Archive book', 'Archivar libro', '封存帳簿'),
        ('action.book.restore', 'Restore book', 'Restaurar libro', '還原帳簿'),
        ('action.book.delete', 'Permanently delete book', 'Eliminar libro permanentemente', '永久刪除帳簿'),
        ('action.book.create', 'Create book', 'Crear libro', '建立帳簿'),
        ('action.account.add-subaccount', 'Add subaccount', 'Agregar subcuenta', '新增子科目'),
        ('action.account.create', 'Create account', 'Crear cuenta', '建立科目'),
        ('action.report.refresh', 'Refresh', 'Actualizar', '重新整理'),
        ('action.uk-company.save', 'Save UK company settings', 'Guardar configuración de empresa del Reino Unido', '儲存英國公司設定'),
        ('action.panama-business.save', 'Save Panama business settings', 'Guardar configuración de empresa panameña', '儲存巴拿馬企業設定'),
        ('action.taiwan-business.save', 'Save Taiwan business settings', 'Guardar configuración de empresa taiwanesa', '儲存臺灣企業設定'),
        ('action.transaction.new', 'New transaction', 'Nueva transacción', '新增交易'),
        ('state.current', 'Current', 'Actual', '目前'),
        ('state.from-beginning', 'From the beginning', 'Desde el inicio', '自最初起'),
        ('state.from-date', 'From {date}', 'Desde {date}', '自 {date} 起'),
        ('state.archived', 'Archived', 'Archivado', '已封存'),
        ('state.cash', 'Cash', 'Efectivo', '現金'),
        ('state.generic-business', 'Generic business', 'Negocio genérico', '一般企業'),
        ('state.one-accounting-period', 'One accounting period', 'Un período contable', '一個會計期間'),
        ('state.panama-property-pack', 'Panama property pack', 'Paquete de propiedad de Panamá', '巴拿馬物業套件'),
        ('state.panama-business', 'Panama business', 'Empresa de Panamá', '巴拿馬企業'),
        ('state.taiwan-manufacturing', 'Taiwan manufacturing', 'Manufactura de Taiwán', '臺灣製造業'),
        ('state.taiwan-business', 'Taiwan business', 'Empresa de Taiwán', '臺灣企業'),
        ('state.uk-company-ready', 'UK setup complete', 'Configuración del Reino Unido completa', '英國公司設定已完成'),
        ('state.uk-company-setup', 'UK setup incomplete', 'Configuración del Reino Unido incompleta', '英國公司設定未完成'),
        ('note.permanent', 'Permanent', 'Permanente', '永久'),
        ('note.owner-entity', 'Controls which optional business packs may be configured', 'Controla qué paquetes empresariales opcionales pueden configurarse', '控制可設定的選用企業套件'),
        ('note.currency-history', 'Dated reports use the applicable currency history', 'Los informes fechados usan el historial de moneda aplicable', '日期型報表使用適用的幣別歷史'),
        ('note.period-id', 'Stable key; it cannot be changed after setup.', 'Clave estable; no puede cambiarse después de la configuración.', '穩定識別碼；設定完成後不可更改。'),
        ('note.period-id-company', 'Stable key; it cannot be changed after company setup.', 'Clave estable; no puede cambiarse después de configurar la empresa.', '穩定識別碼；公司設定完成後不可更改。'),
        ('help.book.identity', 'The identifier is permanent. Entity type and reporting currency are explicit settings, never guesses from the name or currency.', 'El identificador es permanente. El tipo de entidad y la moneda de presentación son ajustes explícitos, nunca suposiciones basadas en el nombre o la moneda.', '識別碼是永久的。實體類型與報表幣別皆為明確設定，不會根據名稱或幣別推測。'),
        ('help.book.no-pack-household', 'No jurisdiction pack is enabled. Household books stay personal unless you explicitly change their entity type.', 'No hay ningún paquete jurisdiccional habilitado. Los libros domésticos siguen siendo personales salvo que cambie explícitamente su tipo de entidad.', '目前未啟用任何司法管轄區套件。除非明確變更實體類型，家庭帳簿會維持個人用途。'),
        ('help.book.no-pack', 'No jurisdiction pack is enabled for this book. Packs are optional and must be configured explicitly.', 'No hay ningún paquete jurisdiccional habilitado para este libro. Los paquetes son opcionales y deben configurarse explícitamente.', '此帳簿未啟用任何司法管轄區套件。套件為選用項目，必須明確設定。'),
        ('help.book.details', 'Changing the display name or entity classification does not change the permanent ledger identifier.', 'Cambiar el nombre visible o la clasificación de la entidad no cambia el identificador permanente del libro mayor.', '變更顯示名稱或實體分類不會改變永久帳簿識別碼。'),
        ('help.book.currency', 'An empty book changes denomination immediately. Once transactions exist, a new currency starts on the effective date; accounts and postings are not rewritten.', 'Un libro vacío cambia de denominación inmediatamente. Cuando ya existen transacciones, la nueva moneda comienza en la fecha de vigencia; las cuentas y los asientos no se reescriben.', '空白帳簿會立即變更計價幣別。已有交易時，新幣別自生效日起使用；科目與分錄不會重寫。'),
        ('help.book.archive', 'Archive hides this book from normal navigation and can be reversed.', 'Archivar oculta este libro de la navegación normal y se puede revertir.', '封存會在一般導覽中隱藏此帳簿，且可還原。'),
        ('help.book.archived', 'Archived {date}. Restore it, or permanently delete it after typing the exact book name.', 'Archivado el {date}. Restáurelo o elimínelo permanentemente después de escribir el nombre exacto del libro.', '已於 {date} 封存。您可以還原，或輸入完整帳簿名稱後永久刪除。'),
        ('help.book.delete-confirmation', 'Type “{name}” to confirm', 'Escriba “{name}” para confirmar', '輸入「{name}」以確認'),
        ('help.uk-company.enabled', 'Update the company profile, reporting period, and VAT control used by UK working-paper reports.', 'Actualice el perfil de la empresa, el período de informe y el control de IVA usados por los papeles de trabajo del Reino Unido.', '更新英國工作底稿報表所使用的公司資料、報告期間與增值稅控制。'),
        ('help.uk-company.disabled', 'Configure this ledger as a UK company to enable the company working-paper reports.', 'Configure este libro mayor como empresa del Reino Unido para habilitar los papeles de trabajo de la empresa.', '將此帳簿設定為英國公司，以啟用公司工作底稿報表。'),
        ('help.uk-company.ledger-source', 'The ledger remains the source of posted amounts; these settings control UK report classification and timing.', 'El libro mayor sigue siendo la fuente de los importes contabilizados; estos ajustes controlan la clasificación y el período de los informes del Reino Unido.', '帳簿仍是已入帳金額的來源；這些設定控制英國報表的分類與期間。'),
        ('help.panama-business.enabled', 'Update the business facts and fiscal period used by the accounting working papers.', 'Actualice los datos del negocio y el período fiscal usados por los papeles de trabajo contables.', '更新會計工作底稿所使用的企業資料與會計年度。'),
        ('help.panama-business.disabled', 'Configure this PAB or USD ledger as a Panama business.', 'Configure este libro mayor en PAB o USD como negocio de Panamá.', '將此 PAB 或 USD 帳簿設定為巴拿馬企業。'),
        ('help.panama-business.disclaimer', 'Njord stores bookkeeping facts and review schedules; it does not determine or file a Panama tax return.', 'Njord almacena datos contables y anexos de revisión; no determina ni presenta una declaración tributaria de Panamá.', 'Njord 儲存簿記事實與覆核明細；不判定或申報巴拿馬稅務申報表。'),
        ('help.taiwan-business.enabled', 'Update the business facts and fiscal period used by the accounting working papers.', 'Actualice los datos del negocio y el período fiscal usados por los papeles de trabajo contables.', '更新會計工作底稿所使用的企業資料與會計年度。'),
        ('help.taiwan-business.disabled', 'Configure this TWD ledger as a Taiwan business.', 'Configure este libro mayor en TWD como negocio de Taiwán.', '將此 TWD 帳簿設定為臺灣企業。'),
        ('help.taiwan-business.disclaimer', 'Njord stores bookkeeping facts and review schedules; it does not determine or file a Taiwan tax return.', 'Njord almacena datos contables y anexos de revisión; no determina ni presenta una declaración tributaria de Taiwán.', 'Njord 儲存簿記事實與覆核明細；不判定或申報臺灣稅務申報表。'),
        ('summary.panama.properties', '{count} properties', '{count} propiedades', '{count} 項物業'),
        ('summary.taiwan.manufacturing', 'Injection moulding · {count} stock items', 'Moldeo por inyección · {count} artículos de inventario', '射出成型 · {count} 項存貨品項'),
        ('label.account.own', 'Own: {value} {asset}', 'Propio: {value} {asset}', '自身：{value} {asset}'),
        ('chart.summary.unavailable', '{label} unavailable', '{label} no disponible', '{label} 無法取得'),
        ('chart.summary.value', '{label}: {value}', '{label}: {value}', '{label}：{value}'),
        ('chart.point.label', '{period}: {label} {value}', '{period}: {label} {value}', '{period}：{label} {value}'),
        ('chart.value.unavailable', 'unavailable', 'no disponible', '無法取得'),
        ('month.short.01', 'Jan', 'ene', '1月'),
        ('month.short.02', 'Feb', 'feb', '2月'),
        ('month.short.03', 'Mar', 'mar', '3月'),
        ('month.short.04', 'Apr', 'abr', '4月'),
        ('month.short.05', 'May', 'may', '5月'),
        ('month.short.06', 'Jun', 'jun', '6月'),
        ('month.short.07', 'Jul', 'jul', '7月'),
        ('month.short.08', 'Aug', 'ago', '8月'),
        ('month.short.09', 'Sep', 'sep', '9月'),
        ('month.short.10', 'Oct', 'oct', '10月'),
        ('month.short.11', 'Nov', 'nov', '11月'),
        ('month.short.12', 'Dec', 'dic', '12月'),
        ('status.loading', 'Loading', 'Cargando', '載入中'),
        ('status.loading.admin', 'Loading administration', 'Cargando administración', '正在載入管理頁面'),
        ('status.loading.book', 'Loading book', 'Cargando libro', '正在載入帳簿'),
        ('status.loading.accounts', 'Loading accounts', 'Cargando cuentas', '正在載入科目'),
        ('status.loading.ledger', 'Loading ledger', 'Cargando libro mayor', '正在載入分類帳'),
        ('status.loading.journal', 'Loading journal', 'Cargando diario', '正在載入日記帳'),
        ('status.loading.reconciliation', 'Loading reconciliation', 'Cargando conciliación', '正在載入對帳'),
        ('status.loading.reports', 'Loading reports', 'Cargando informes', '正在載入報表'),
        ('status.loading.report', 'Loading report', 'Cargando informe', '正在載入報表'),
        ('status.loading.add-book', 'Loading add-book page', 'Cargando la página para agregar libro', '正在載入新增帳簿頁面'),
        ('status.loading.add-account', 'Loading add-account page', 'Cargando la página para agregar cuenta', '正在載入新增科目頁面'),
        ('status.transaction.finish-before-navigation', 'Finish the active register edit before navigating', 'Termine la edición activa del registro antes de navegar', '請先完成目前的登錄簿編輯再瀏覽其他頁面'),
        ('status.admin.inviting-user', 'Inviting user', 'Invitando usuario', '正在邀請使用者'),
        ('status.admin.user-invited', 'User invited', 'Usuario invitado', '已邀請使用者'),
        ('status.book.select-first', 'Select a book first', 'Seleccione primero un libro', '請先選擇帳簿'),
        ('status.report.refreshing', 'Refreshing report', 'Actualizando informe', '正在重新整理報表'),
        ('status.book.creating', 'Creating book', 'Creando libro', '正在建立帳簿'),
        ('status.book.saving-details', 'Saving book details', 'Guardando detalles del libro', '正在儲存帳簿詳細資料'),
        ('status.book.details-saved', 'Book details saved', 'Detalles del libro guardados', '帳簿詳細資料已儲存'),
        ('status.book.updating-currency', 'Updating reporting currency', 'Actualizando moneda de presentación', '正在更新報表幣別'),
        ('status.book.currency-updated', 'Reporting currency updated', 'Moneda de presentación actualizada', '報表幣別已更新'),
        ('status.book.archiving', 'Archiving book', 'Archivando libro', '正在封存帳簿'),
        ('status.book.archived', 'Book archived', 'Libro archivado', '帳簿已封存'),
        ('status.book.restoring', 'Restoring book', 'Restaurando libro', '正在還原帳簿'),
        ('status.book.restored', 'Book restored', 'Libro restaurado', '帳簿已還原'),
        ('status.book.deleting', 'Deleting book', 'Eliminando libro', '正在刪除帳簿'),
        ('status.book.deleted', 'Book deleted', 'Libro eliminado', '帳簿已刪除'),
        ('status.access.adding', 'Adding Book access', 'Agregando acceso al libro', '正在新增帳簿存取權'),
        ('status.access.changing', 'Changing Book access', 'Cambiando acceso al libro', '正在變更帳簿存取權'),
        ('status.access.removing', 'Removing Book access', 'Quitando acceso al libro', '正在移除帳簿存取權'),
        ('status.access.updated', 'Book access updated', 'Acceso al libro actualizado', '帳簿存取權已更新'),
        ('status.uk-company.saving', 'Saving UK company settings', 'Guardando configuración de empresa del Reino Unido', '正在儲存英國公司設定'),
        ('status.uk-company.saved', 'UK company settings saved', 'Configuración de empresa del Reino Unido guardada', '英國公司設定已儲存'),
        ('status.panama-business.saving', 'Saving Panama business settings', 'Guardando configuración de negocio de Panamá', '正在儲存巴拿馬企業設定'),
        ('status.panama-business.saved', 'Panama business settings saved', 'Configuración de negocio de Panamá guardada', '巴拿馬企業設定已儲存'),
        ('status.taiwan-business.saving', 'Saving Taiwan business settings', 'Guardando configuración de negocio de Taiwán', '正在儲存臺灣企業設定'),
        ('status.taiwan-business.saved', 'Taiwan business settings saved', 'Configuración de negocio de Taiwán guardada', '臺灣企業設定已儲存'),
        ('status.account.creating', 'Creating account', 'Creando cuenta', '正在建立科目'),
        ('status.ledger.refreshing', 'Refreshing ledger', 'Actualizando libro mayor', '正在重新整理分類帳'),
        ('status.reconciliation.marking', 'Marking posting reconciled', 'Marcando asiento como conciliado', '正在將分錄標記為已對帳'),
        ('status.reconciliation.reopening', 'Reopening posting', 'Reabriendo asiento', '正在重新開啟分錄'),
        ('status.reconciliation.reconciled', 'Posting reconciled', 'Asiento conciliado', '分錄已對帳'),
        ('status.reconciliation.reopened', 'Posting reopened', 'Asiento reabierto', '分錄已重新開啟'),
        ('status.field.cancelled', 'Field edit cancelled', 'Edición del campo cancelada', '欄位編輯已取消'),
        ('status.transaction.editing', 'Editing transaction', 'Editando transacción', '正在編輯交易'),
        ('status.transaction.saving', 'Saving transaction', 'Guardando transacción', '正在儲存交易'),
        ('status.transaction.saved-not-visible', 'Transaction saved; selected transaction is no longer in this ledger', 'Transacción guardada; la transacción seleccionada ya no está en este libro mayor', '交易已儲存；所選交易已不在此分類帳中'),
        ('error.transaction-refresh', 'Transaction saved; ledger refresh failed: {error}', 'Transacción guardada; falló la actualización del libro mayor: {error}', '交易已儲存；分類帳重新整理失敗：{error}'),
        ('error.database.no-rows', 'The database function returned no rows', 'La función de la base de datos no devolvió filas', '資料庫函式未傳回任何資料列'),
        ('error.bad-url', 'Bad URL: {url}', 'URL no válida: {url}', '無效的網址：{url}'),
        ('error.timeout', 'The request timed out', 'La solicitud agotó el tiempo de espera', '要求逾時'),
        ('error.network', 'Cannot reach the local server', 'No se puede acceder al servidor local', '無法連線至本機伺服器'),
        ('error.http-status', 'HTTP error {status}', 'Error HTTP {status}', 'HTTP 錯誤 {status}'),
        ('error.database', 'HTTP {status}: {message}', 'HTTP {status}: {message}', 'HTTP {status}：{message}'),
        ('error.database-detail', 'HTTP {status}: {message} ({details})', 'HTTP {status}: {message} ({details})', 'HTTP {status}：{message}（{details}）'),
        ('error.database-body', 'HTTP {status}: {body}', 'HTTP {status}: {body}', 'HTTP {status}：{body}'),
        ('error.response-invalid', 'Invalid server response: {details}', 'Respuesta del servidor no válida: {details}', '伺服器回應無效：{details}'),
        ('aria.transaction.edit', 'Edit transaction on {date}', 'Editar transacción del {date}', '編輯 {date} 的交易'),
        ('aria.account.add-subaccount', 'Add subaccount to {account}', 'Agregar subcuenta a {account}', '在 {account} 下新增子科目'),
        ('aria.account.open-register', 'Open {account} register', 'Abrir el registro de {account}', '開啟 {account} 登錄簿'),
        ('aria.account.collapse', 'Collapse {account}', 'Contraer {account}', '收合 {account}'),
        ('aria.account.expand', 'Expand {account}', 'Expandir {account}', '展開 {account}'),
        ('aria.account.mixed-commodity', 'This branch contains more than one commodity', 'Esta rama contiene más de un producto', '此分支包含多種商品'),
        ('aria.chart.bar', 'Bar chart. {summary}', 'Gráfico de barras. {summary}', '長條圖。{summary}'),
        ('aria.split.memo', 'Blank split memo', 'Nota de división vacía', '空白拆分備註'),
        ('aria.split.account', 'Blank split account', 'Cuenta de división vacía', '空白拆分科目'),
        ('aria.split.deposit', 'Blank split deposit', 'Depósito de división vacío', '空白拆分存入金額'),
        ('aria.split.withdrawal', 'Blank split withdrawal', 'Retiro de división vacío', '空白拆分支出金額'),
        ('aria.transaction.new-date', 'New transaction date', 'Fecha de la nueva transacción', '新交易日期'),
        ('aria.transaction.new-description', 'New transaction description', 'Descripción de la nueva transacción', '新交易說明'),
        ('aria.transaction.new-deposit', 'New transaction deposit', 'Depósito de la nueva transacción', '新交易存入金額'),
        ('aria.transaction.new-withdrawal', 'New transaction withdrawal', 'Retiro de la nueva transacción', '新交易支出金額')
), presentation_text(locale, semantic_key, display_text) AS (
    SELECT
        translation.locale,
        vocabulary.semantic_key,
        translation.display_text
    FROM vocabulary
    CROSS JOIN LATERAL (VALUES
        ('en-GB'::VARCHAR, vocabulary."en-GB"),
        ('es-PA'::VARCHAR, vocabulary."es-PA"),
        ('zh-TW'::VARCHAR, vocabulary."zh-TW")
    ) AS translation(locale, display_text)
)
INSERT INTO presentation.messages (locale, semantic_key, display_text)
SELECT locale, semantic_key, display_text
FROM presentation_text;

-- A language does not become selectable until it has exact key parity with
-- the canonical English catalogue. Failing the install is preferable to
-- exposing a silently mixed-language UI.
DO $$
DECLARE
    candidate_locale VARCHAR;
BEGIN
    FOREACH candidate_locale IN ARRAY ARRAY['es-PA', 'zh-TW'] LOOP
        IF EXISTS (
            (SELECT semantic_key FROM presentation.messages WHERE locale = 'en-GB'
             EXCEPT
             SELECT semantic_key FROM presentation.messages WHERE locale = candidate_locale)
            UNION ALL
            (SELECT semantic_key FROM presentation.messages WHERE locale = candidate_locale
             EXCEPT
             SELECT semantic_key FROM presentation.messages WHERE locale = 'en-GB')
        ) THEN
            RAISE EXCEPTION 'presentation catalogue for % is incomplete', candidate_locale;
        END IF;
    END LOOP;

    UPDATE presentation.locales
    SET enabled = TRUE,
        complete = TRUE
    WHERE locale IN ('es-PA', 'zh-TW');
END;
$$;

CREATE OR REPLACE FUNCTION presentation.requested_locale()
RETURNS VARCHAR
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    request_headers JSONB;
BEGIN
    BEGIN
        request_headers := NULLIF(
            current_setting('request.headers', TRUE), ''
        )::JSONB;
    EXCEPTION WHEN OTHERS THEN
        request_headers := NULL;
    END;

    RETURN NULLIF(
        btrim(split_part(split_part(
            COALESCE(request_headers ->> 'accept-language', ''), ',', 1
        ), ';', 1)),
        ''
    );
END;
$$;

CREATE OR REPLACE FUNCTION presentation.resolve_locale(
    p_requested_locale VARCHAR DEFAULT NULL
)
RETURNS VARCHAR
LANGUAGE SQL
STABLE
AS $$
    SELECT COALESCE(
        (
            SELECT locale
            FROM presentation.locales
            WHERE enabled AND complete
              AND lower(locale) = lower(COALESCE(
                  p_requested_locale, presentation.requested_locale()
              ))
            LIMIT 1
        ),
        (
            SELECT locale
            FROM presentation.locales
            WHERE enabled AND complete
              AND lower(split_part(locale, '-', 1)) = lower(split_part(
                  COALESCE(p_requested_locale, presentation.requested_locale(), ''),
                  '-', 1
              ))
            ORDER BY locale
            LIMIT 1
        ),
        'en-GB'
    );
$$;

CREATE OR REPLACE FUNCTION presentation.text(
    p_semantic_key VARCHAR,
    p_requested_locale VARCHAR DEFAULT NULL
)
RETURNS TEXT
LANGUAGE SQL
STABLE
AS $$
    WITH RECURSIVE locale_chain(locale, fallback_locale, depth) AS (
        SELECT locales.locale, locales.fallback_locale, 0
        FROM presentation.locales AS locales
        WHERE locales.locale = presentation.resolve_locale(p_requested_locale)
      UNION ALL
        SELECT fallback.locale, fallback.fallback_locale, locale_chain.depth + 1
        FROM locale_chain
        JOIN presentation.locales AS fallback
          ON fallback.locale = locale_chain.fallback_locale
        WHERE locale_chain.depth < 8
    )
    SELECT messages.display_text
    FROM locale_chain
    JOIN presentation.messages AS messages USING (locale)
    WHERE messages.semantic_key = p_semantic_key
    ORDER BY locale_chain.depth
    LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION api.presentation_catalogue(
    p_locale VARCHAR DEFAULT NULL
)
RETURNS SETOF api.page_component
LANGUAGE SQL
STABLE
AS $$
    WITH resolved AS (
        SELECT presentation.resolve_locale(p_locale) AS locale
    ), catalogue_rows AS (
        SELECT
            'language_option'::VARCHAR AS component,
            90000::BIGINT + row_number() OVER (ORDER BY locales.locale) AS row_order,
            locales.locale::VARCHAR AS row_key,
            jsonb_build_object(
                'locale', locales.locale,
                'flag', locales.flag,
                'label', presentation.text('language.' || locales.locale, resolved.locale)
            ) AS payload
        FROM presentation.locales AS locales
        CROSS JOIN resolved
        WHERE locales.enabled AND locales.complete

        UNION ALL

        SELECT
            'presentation'::VARCHAR,
            100000::BIGINT + row_number() OVER (ORDER BY messages.semantic_key),
            messages.semantic_key,
            jsonb_build_object(
                'key', messages.semantic_key,
                'text', presentation.text(messages.semantic_key, resolved.locale),
                'locale', resolved.locale
            )
        FROM presentation.messages AS messages
        CROSS JOIN resolved
        WHERE messages.locale = 'en-GB'
    )
    SELECT
        component, row_order, row_key, payload
    FROM catalogue_rows
    ORDER BY row_order, row_key;
$$;
