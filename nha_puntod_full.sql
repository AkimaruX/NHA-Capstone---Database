-- NHA-Puntod Portal — final normalized (3NF) schema for MariaDB 10.4+ / MySQL 8.0.16+ (InnoDB, utf8mb4)
--
-- CLEAN INSTALL ONLY. This script DROPS and recreates the `nha_puntod` database.
-- Existing data?  Do NOT run this file.  Back up, then run:  php backend/database/migrate.php
-- Then (optional demo data):  php backend/database/seed.php --history
--
-- KEY RULE: every person who acts as personnel (assigns, approves, verifies, changes settings) is referenced through
--   employee_profiles(user_id); every client owner of a transaction/document through client_profiles(user_id). There is no
--   staff table: an employee's id IS users.user_id. A client or employee account therefore must have its profile row.
-- Four roles: admin (System Admin), management, staff, client.
-- roles.role_name is the one stored name of a role (the screens show it as System Admin / Management / Staff / Client).
-- Management and Staff accounts have a POSITION (positions table). Permissions = role defaults + position defaults
-- (Staff positions each carry their own). Permissions are fixed; there are no per-person exceptions.

DROP DATABASE IF EXISTS nha_puntod;
CREATE DATABASE nha_puntod CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE nha_puntod;

-- ═════════ ACCOUNTS & ROLES ═════════
CREATE TABLE roles (
    role_id    TINYINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    role_name  VARCHAR(20) NOT NULL,
    UNIQUE KEY uq_roles_name (role_name)
) ENGINE=InnoDB;

-- One row per person (sign-in details + name shared by every role).
-- A walk-in applicant is a client record created by staff with no e-mail and no password (both NULL): no login.
CREATE TABLE users (
    user_id              INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    role_id              TINYINT UNSIGNED NOT NULL,
    email                VARCHAR(255) NULL,
    password_hash        VARCHAR(255) NULL,
    first_name           VARCHAR(100) NOT NULL,
    middle_name          VARCHAR(100) NULL,
    last_name            VARCHAR(100) NOT NULL DEFAULT '',
    phone                VARCHAR(20)  NULL,
    is_active            TINYINT(1)   NOT NULL DEFAULT 1,
    must_change_password TINYINT(1)   NOT NULL DEFAULT 0,
    last_login_at        DATETIME NULL,
    created_at           DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uq_users_email (email),
    KEY idx_users_role_active (role_id, is_active),
    KEY idx_users_name (last_name, first_name),
    CONSTRAINT fk_users_role FOREIGN KEY (role_id) REFERENCES roles(role_id) ON UPDATE CASCADE ON DELETE RESTRICT
) ENGINE=InnoDB;

-- A place a client lives: province, city, barangay, purok and street. Clients point to a row here (client_profiles.location_id)
-- instead of carrying the address text themselves; clients in the same place can share one row.
CREATE TABLE locations (
    location_id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    province    VARCHAR(80)  NOT NULL,
    city        VARCHAR(80)  NOT NULL,
    barangay    VARCHAR(80)  NOT NULL,
    purok       VARCHAR(50)  NULL,
    street      VARCHAR(150) NULL,
    KEY idx_locations_area (province, city, barangay)
) ENGINE=InnoDB;

-- 1:1 with users for client accounts (the API creates this row together with the client account; its columns may be NULL).
-- It is the target of transactions.client_id and documents.client_id, so only a client can own a transaction or a file.
-- Date of birth, monthly income and household size depend only on the client, so they stay here (3NF).
-- The address is the client's location (locations: province, city, barangay, purok, street).
CREATE TABLE client_profiles (
    user_id        INT UNSIGNED PRIMARY KEY,
    date_of_birth  DATE NULL,
    location_id    INT UNSIGNED NULL,
    monthly_income DECIMAL(10,2) NULL,
    household_size TINYINT UNSIGNED NULL,
    CONSTRAINT fk_client_profile_user FOREIGN KEY (user_id) REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_client_profile_location FOREIGN KEY (location_id) REFERENCES locations(location_id) ON UPDATE CASCADE ON DELETE RESTRICT
) ENGINE=InnoDB;

CREATE TABLE departments (
    department_id   TINYINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    department_name VARCHAR(60) NOT NULL,
    UNIQUE KEY uq_department_name (department_name)
) ENGINE=InnoDB;

-- A position belongs to exactly one role (Management or Staff). System Admin accounts have no position.
CREATE TABLE positions (
    position_id   TINYINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    role_id       TINYINT UNSIGNED NOT NULL,
    position_name VARCHAR(60) NOT NULL,
    UNIQUE KEY uq_position_name (position_name),
    KEY idx_positions_role (role_id),
    CONSTRAINT fk_positions_role FOREIGN KEY (role_id) REFERENCES roles(role_id) ON UPDATE CASCADE ON DELETE RESTRICT
) ENGINE=InnoDB;

-- 1:1 with users for admin / management / staff accounts: the personnel record (the API creates it with the account).
-- It is the target of every 'done by personnel' key (assignee, assigner, approver, verifier, settings editor).
-- The API checks that position_id belongs to the same role as the user.
CREATE TABLE employee_profiles (
    user_id           INT UNSIGNED PRIMARY KEY,
    employee_number   VARCHAR(30) NULL,
    position_id       TINYINT UNSIGNED NULL,
    department_id     TINYINT UNSIGNED NULL,
    employment_status ENUM('active','on_leave','separated') NOT NULL DEFAULT 'active',
    UNIQUE KEY uq_employee_number (employee_number),
    KEY idx_employee_position (position_id),
    KEY idx_employee_department (department_id),
    CONSTRAINT fk_employee_profile_user       FOREIGN KEY (user_id)       REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_employee_profile_position   FOREIGN KEY (position_id)   REFERENCES positions(position_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_employee_profile_department FOREIGN KEY (department_id) REFERENCES departments(department_id) ON UPDATE CASCADE ON DELETE RESTRICT
) ENGINE=InnoDB;

-- ═════════ SESSIONS, LOGIN ATTEMPTS, PASSWORD RECOVERY, SETTINGS ═════════
CREATE TABLE sessions (
    session_id       INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    user_id          INT UNSIGNED NOT NULL,
    token_hash       CHAR(64) NOT NULL,
    created_at       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_activity_at DATETIME NULL,
    expires_at       DATETIME NOT NULL,
    UNIQUE KEY uq_session_token_hash (token_hash),
    KEY idx_sessions_user_expiry (user_id, expires_at),
    KEY idx_sessions_expiry (expires_at),
    CONSTRAINT fk_sessions_user FOREIGN KEY (user_id) REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE CASCADE
) ENGINE=InnoDB;

-- A failed sign-in (or wrong reset code) for an e-mail. Used to lock an e-mail after too many failures.
CREATE TABLE login_attempts (
    attempt_id    INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    email_entered VARCHAR(255) NOT NULL,
    attempted_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    KEY idx_attempt_email (email_entered, attempted_at)
) ENGINE=InnoDB;

CREATE TABLE password_resets (
    reset_id   INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    user_id    INT UNSIGNED NOT NULL,
    token_hash CHAR(64) NOT NULL,
    expires_at DATETIME NOT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uq_password_reset_token_hash (token_hash),
    KEY idx_password_reset_user_expiry (user_id, expires_at),
    CONSTRAINT fk_password_reset_user FOREIGN KEY (user_id) REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE CASCADE
) ENGINE=InnoDB;

-- Administrator-editable security settings (key/value).
CREATE TABLE system_settings (
    setting_key   VARCHAR(50) PRIMARY KEY,
    setting_value VARCHAR(100) NOT NULL,
    updated_by    INT UNSIGNED NULL,
    updated_at    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    KEY idx_system_settings_user (updated_by),
    CONSTRAINT fk_system_settings_user FOREIGN KEY (updated_by) REFERENCES employee_profiles(user_id) ON UPDATE CASCADE ON DELETE SET NULL
) ENGINE=InnoDB;

-- ═════════ PERMISSIONS (RBAC) ═════════
-- permission_code is what the program checks (e.g. view_documents); description is the plain-words label shown on screen.
CREATE TABLE permissions (
    permission_id   SMALLINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    permission_code VARCHAR(50)  NOT NULL,
    description     VARCHAR(120) NOT NULL,
    UNIQUE KEY uq_permission_code (permission_code)
) ENGINE=InnoDB;

-- Default permissions of each role (identical for every account of that role)
CREATE TABLE role_permissions (
    role_id       TINYINT UNSIGNED  NOT NULL,
    permission_id SMALLINT UNSIGNED NOT NULL,
    PRIMARY KEY (role_id, permission_id),
    KEY idx_role_permissions_permission (permission_id),
    CONSTRAINT fk_role_permissions_role FOREIGN KEY (role_id) REFERENCES roles(role_id) ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_role_permissions_permission FOREIGN KEY (permission_id) REFERENCES permissions(permission_id) ON UPDATE CASCADE ON DELETE CASCADE
) ENGINE=InnoDB;

-- Extra default permissions of a position (this is how each Staff position gets its own permissions)
CREATE TABLE position_permissions (
    position_id   TINYINT UNSIGNED  NOT NULL,
    permission_id SMALLINT UNSIGNED NOT NULL,
    PRIMARY KEY (position_id, permission_id),
    KEY idx_position_permissions_permission (permission_id),
    CONSTRAINT fk_position_permissions_position   FOREIGN KEY (position_id)   REFERENCES positions(position_id) ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_position_permissions_permission FOREIGN KEY (permission_id) REFERENCES permissions(permission_id) ON UPDATE CASCADE ON DELETE CASCADE
) ENGINE=InnoDB;

-- ═════════ AUDIT LOG (append-only) ═════════
-- Who did it = user_id (name read from users; NULL when nobody was signed in, e.g. a failed sign-in).
-- target = what it was about, e.g. "transaction TXN-2026-001" or "document d12".
CREATE TABLE audit_logs (
    log_id     BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    user_id    INT UNSIGNED NULL,
    action     VARCHAR(50)  NOT NULL,
    target     VARCHAR(80)  NULL,
    details    TEXT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    KEY idx_audit_time (created_at),
    KEY idx_audit_user (user_id, created_at),
    KEY idx_audit_action (action, created_at),
    KEY idx_audit_target (target),
    CONSTRAINT fk_audit_log_user FOREIGN KEY (user_id) REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE SET NULL
) ENGINE=InnoDB;

-- ═════════ APPLICATIONS / TRANSACTIONS ═════════
CREATE TABLE application_types (
    application_type_id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    type_name           VARCHAR(100) NOT NULL,
    UNIQUE KEY uq_application_type_name (type_name)
) ENGINE=InnoDB;

-- A requirement (e.g. 'Valid Government ID') is stored ONCE and linked to every application type that needs it
-- (many-to-many), so its name is not repeated per type.
CREATE TABLE requirements (
    requirement_id   INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    requirement_name VARCHAR(150) NOT NULL,
    UNIQUE KEY uq_requirement_name (requirement_name)
) ENGINE=InnoDB;

CREATE TABLE application_type_requirements (
    application_type_id INT UNSIGNED NOT NULL,
    requirement_id      INT UNSIGNED NOT NULL,
    PRIMARY KEY (application_type_id, requirement_id),
    KEY idx_atr_requirement (requirement_id),
    CONSTRAINT fk_atr_type        FOREIGN KEY (application_type_id) REFERENCES application_types(application_type_id) ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_atr_requirement FOREIGN KEY (requirement_id)      REFERENCES requirements(requirement_id) ON UPDATE CASCADE ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE transaction_statuses (
    transaction_status_id TINYINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    status_name           VARCHAR(20) NOT NULL,
    UNIQUE KEY uq_transaction_status_name (status_name)
) ENGINE=InnoDB;

-- client_id is always a client (client_profiles.user_id); walk-in applicants get a client account + profile created by staff. The applicant's address, income and
-- household size are the client's (client_profiles); they are not copied onto the transaction.
-- The current assignee is NOT stored here: it is the newest row of transaction_assignments (view current_assignments).
-- Approval by Management is recorded separately (approved_by / approved_at) and does not change the status flow.
-- approved_by is an employee (employee_profiles.user_id), so only personnel records can be approvers.
CREATE TABLE transactions (
    transaction_id        INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    reference_no          VARCHAR(30) NOT NULL,
    client_id             INT UNSIGNED NOT NULL,
    application_type_id   INT UNSIGNED NOT NULL,
    transaction_status_id TINYINT UNSIGNED NOT NULL,
    notes                 TEXT NULL,
    submitted_at          DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    completed_at          DATE NULL,
    approved_by           INT UNSIGNED NULL,
    approved_at           DATETIME NULL,
    UNIQUE KEY uq_transaction_reference (reference_no),
    UNIQUE KEY uq_transaction_client (transaction_id, client_id),
    KEY idx_transactions_client_date (client_id, submitted_at),
    KEY idx_transactions_status_date (transaction_status_id, submitted_at),
    KEY idx_transactions_type_date (application_type_id, submitted_at),
    KEY idx_transactions_approved_by (approved_by),
    CONSTRAINT fk_transaction_client   FOREIGN KEY (client_id)             REFERENCES client_profiles(user_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_transaction_type     FOREIGN KEY (application_type_id)   REFERENCES application_types(application_type_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_transaction_status   FOREIGN KEY (transaction_status_id) REFERENCES transaction_statuses(transaction_status_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_transaction_approver FOREIGN KEY (approved_by)           REFERENCES employee_profiles(user_id) ON UPDATE CASCADE ON DELETE SET NULL
) ENGINE=InnoDB;

-- Every assignment / reassignment. The row with the highest assignment_id for a transaction is the current assignment.
-- employee_id is an EMPLOYEE (employee_profiles.user_id, which is the same number as users.user_id): there is no separate staff table.
-- The database therefore guarantees the assignee has a personnel record; the API additionally checks that the account's role is 'staff'.
CREATE TABLE transaction_assignments (
    assignment_id  INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    transaction_id INT UNSIGNED NOT NULL,
    employee_id    INT UNSIGNED NOT NULL,
    assigned_by    INT UNSIGNED NULL,
    assigned_at    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    KEY idx_assignment_transaction (transaction_id, assignment_id),
    KEY idx_assignment_employee (employee_id),
    KEY idx_assignment_assigned_by (assigned_by),
    CONSTRAINT fk_assignment_transaction FOREIGN KEY (transaction_id) REFERENCES transactions(transaction_id) ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_assignment_employee FOREIGN KEY (employee_id) REFERENCES employee_profiles(user_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_assignment_assigner FOREIGN KEY (assigned_by) REFERENCES employee_profiles(user_id) ON UPDATE CASCADE ON DELETE SET NULL
) ENGINE=InnoDB;

CREATE VIEW current_assignments AS
    SELECT a.transaction_id, a.employee_id, a.assigned_by, a.assigned_at
    FROM transaction_assignments a
    WHERE a.assignment_id = (SELECT MAX(x.assignment_id) FROM transaction_assignments x WHERE x.transaction_id = a.transaction_id);

-- One row every time an application is submitted or its status changes (feeds the Track Status timeline)
CREATE TABLE transaction_status_history (
    history_id            INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    transaction_id        INT UNSIGNED NOT NULL,
    transaction_status_id TINYINT UNSIGNED NOT NULL,
    changed_by            INT UNSIGNED NULL,
    remarks               TEXT NULL,
    changed_at            DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    KEY idx_status_history_timeline (transaction_id, changed_at, history_id),
    KEY idx_status_history_status (transaction_status_id),
    KEY idx_status_history_user (changed_by),
    CONSTRAINT fk_status_history_transaction FOREIGN KEY (transaction_id)        REFERENCES transactions(transaction_id) ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_status_history_status      FOREIGN KEY (transaction_status_id) REFERENCES transaction_statuses(transaction_status_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_status_history_user        FOREIGN KEY (changed_by)            REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE SET NULL
) ENGINE=InnoDB;

-- ═════════ DOCUMENTS ═════════
CREATE TABLE document_types (
    document_type_id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    type_name        VARCHAR(100) NOT NULL,
    UNIQUE KEY uq_document_type_name (type_name)
) ENGINE=InnoDB;

CREATE TABLE document_statuses (
    document_status_id TINYINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    status_name        VARCHAR(20) NOT NULL,
    UNIQUE KEY uq_document_status_name (status_name)
) ENGINE=InnoDB;

-- Rules enforced by the API (CHECK constraints are avoided because MySQL refuses them on FK-action columns):
--   a document with a transaction must carry that transaction's client_id;
--   approved_by is only set together with approved_at.
-- The printed code (DOC-2026-00012) and the file type are worked out by the program (from document_id/uploaded_at and the file extension).
-- client_id is the owner (a client's file, optionally attached to one of THEIR transactions via the composite key); a file with no
-- client is an office record. requirement_id says which required document it satisfies (the API checks it is required by the
-- transaction's application type, i.e. present in application_type_requirements). verified_by is an employee.
CREATE TABLE documents (
    document_id          INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    document_type_id     INT UNSIGNED NOT NULL,
    document_status_id   TINYINT UNSIGNED NOT NULL,
    transaction_id       INT UNSIGNED NULL,
    client_id            INT UNSIGNED NULL,
    requirement_id       INT UNSIGNED NULL,
    uploaded_by          INT UNSIGNED NOT NULL,
    display_name         VARCHAR(255) NOT NULL,
    description          VARCHAR(500) NULL,
    stored_filename      VARCHAR(255) NOT NULL,
    file_size_bytes      INT UNSIGNED NOT NULL,
    uploaded_at          DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    verified_by          INT UNSIGNED NULL,
    verified_at          DATETIME NULL,
    verification_remarks VARCHAR(500) NULL,
    archived_at          DATETIME NULL,
    UNIQUE KEY uq_document_stored_filename (stored_filename),
    KEY idx_documents_transaction_client (transaction_id, client_id),
    KEY idx_documents_client_date (client_id, uploaded_at),
    KEY idx_documents_type_status (document_type_id, document_status_id),
    KEY idx_documents_status (document_status_id),
    KEY idx_documents_uploader_date (uploaded_by, uploaded_at),
    KEY idx_documents_requirement (requirement_id),
    KEY idx_documents_verified_by (verified_by),
    CONSTRAINT fk_document_type        FOREIGN KEY (document_type_id)   REFERENCES document_types(document_type_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_document_status      FOREIGN KEY (document_status_id) REFERENCES document_statuses(document_status_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_document_txn_client  FOREIGN KEY (transaction_id, client_id) REFERENCES transactions(transaction_id, client_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_document_client      FOREIGN KEY (client_id)          REFERENCES client_profiles(user_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_document_requirement FOREIGN KEY (requirement_id)     REFERENCES requirements(requirement_id) ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT fk_document_uploader    FOREIGN KEY (uploaded_by)        REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_document_verifier    FOREIGN KEY (verified_by)        REFERENCES employee_profiles(user_id) ON UPDATE CASCADE ON DELETE SET NULL
) ENGINE=InnoDB;

-- ═════════ NOTIFICATIONS ═════════
CREATE TABLE notifications (
    notification_id      INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    user_id              INT UNSIGNED NOT NULL,
    notification_type    ENUM('info','success','warning') NOT NULL DEFAULT 'info',
    message              TEXT NOT NULL,
    transaction_id       INT UNSIGNED NULL,
    is_read              TINYINT(1) NOT NULL DEFAULT 0,
    created_at           DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    KEY idx_notifications_user_read_date (user_id, is_read, created_at),
    KEY idx_notifications_transaction (transaction_id),
    CONSTRAINT fk_notification_user        FOREIGN KEY (user_id)              REFERENCES users(user_id) ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_notification_transaction FOREIGN KEY (transaction_id)       REFERENCES transactions(transaction_id) ON UPDATE CASCADE ON DELETE SET NULL
) ENGINE=InnoDB;

-- ═════════ REFERENCE DATA (needed for the system to work) ═════════
INSERT INTO roles (role_id, role_name) VALUES (1, 'admin'), (2, 'staff'), (3, 'client'), (4, 'management');

INSERT INTO locations (province, city, barangay) VALUES ('Misamis Oriental', 'Cagayan de Oro City', 'Puntod');  -- city/barangay from the capstone title; add other places as clients register

INSERT INTO departments (department_name) VALUES ('Records Management'), ('Administrative Services'), ('Client Services'), ('Office Management');

INSERT INTO positions (role_id, position_name) VALUES
    (4, 'Head of Office'), (4, 'Officer in Charge'), (4, 'Department Head'), (4, 'Administrative Services Head'),
    (4, 'Records Management Supervisor'), (4, 'Client Services Supervisor'), (4, 'Project Supervisor'),
    (2, 'Records Officer'), (2, 'Client Service Officer'), (2, 'Human Resource Officer');

INSERT INTO permissions (permission_code, description) VALUES
 ('view_personnel',       'View personnel records'),
 ('manage_personnel',     'Edit personnel records'),
 ('view_documents',       'View and download documents'),
 ('process_documents',    'Upload, verify, archive and restore documents'),
 ('view_transactions',    'View client transactions'),
 ('process_transactions', 'Update transaction status and record walk-in transactions'),
 ('assign_transactions',  'Assign or reassign transactions to staff'),
 ('approve_transactions', 'Approve transactions'),
 ('view_analytics',       'View dashboards and analytics'),
 ('view_reports',         'Open and filter reports'),
 ('generate_reports',     'Print or export reports'),
 ('manage_users',         'Manage accounts, positions and passwords'),
 ('view_audit_logs',      'Read the activity log'),
 ('manage_settings',      'Change security settings');

-- System Admin: everything
INSERT INTO role_permissions (role_id, permission_id) SELECT 1, permission_id FROM permissions;
-- Management (all seven positions share these): supervision, assignment, approval, reports and audit review
INSERT INTO role_permissions (role_id, permission_id) SELECT 4, permission_id FROM permissions
 WHERE permission_code IN ('view_personnel','view_documents','view_transactions','assign_transactions','approve_transactions','view_analytics','view_reports','generate_reports','view_audit_logs');
-- Staff: every Staff position can open reports; everything else comes from the position (below)
INSERT INTO role_permissions (role_id, permission_id) SELECT 2, permission_id FROM permissions WHERE permission_code = 'view_reports';
-- Client (role 3): no permission rows — clients are limited to their own records by the API itself.

-- Staff positions: each has its own (fixed) permissions
INSERT INTO position_permissions (position_id, permission_id)
 SELECT p.position_id, x.permission_id FROM positions p JOIN permissions x
   ON (p.position_name = 'Records Officer'          AND x.permission_code IN ('view_documents','process_documents'))
   OR (p.position_name = 'Client Service Officer'   AND x.permission_code IN ('view_documents','process_documents','view_transactions','process_transactions'))
   OR (p.position_name = 'Human Resource Officer'   AND x.permission_code IN ('view_personnel','manage_personnel'));

INSERT INTO system_settings (setting_key, setting_value) VALUES
 ('session_idle_minutes', '30'), ('max_login_failures', '5'), ('lockout_minutes', '15');

INSERT INTO transaction_statuses (status_name) VALUES ('pending'), ('ongoing'), ('completed'), ('delayed');
INSERT INTO document_statuses (status_name) VALUES ('active'), ('pending'), ('archived'), ('rejected');
INSERT INTO document_types (type_name) VALUES ('Application Form'), ('Certificate'), ('Award Document'), ('Clearance'),
    ('Financial Document'), ('Technical Document'), ('Identification'), ('General');
INSERT INTO application_types (type_name) VALUES ('Socialized Housing Application'), ('Community Mortgage Program'),
    ('Housing Loan Application'), ('Amortization Update Request'), ('Lot Award Claim');
INSERT INTO requirements (requirement_id, requirement_name) VALUES
    (1,'Barangay Certificate of Indigency'),(2,'Valid Government ID'),(3,'Birth Certificate'),(4,'Income Tax Return / Certificate of Non-Filing'),(5,'Proof of Residency'),
    (6,'Community Resolution'),(7,'Land Title / TCT'),(8,'Barangay Certificate'),(9,'List of Beneficiaries'),(10,'CMP Application Form'),
    (11,'Filled Housing Loan Form'),(12,'Latest 3 Months Payslips'),(13,'BIR Form 2316'),(14,'Employment Certificate'),(15,'Property Documents'),
    (16,'Account Number / Contract'),(17,'Reason Letter'),(18,'Income Documents'),(19,'Lot Award Notice');
-- application type ids follow the INSERT order above: 1 Socialized Housing, 2 CMP, 3 Housing Loan, 4 Amortization Update, 5 Lot Award Claim
INSERT INTO application_type_requirements (application_type_id, requirement_id) VALUES
    (1,1),(1,2),(1,3),(1,4),(1,5),
    (2,6),(2,7),(2,8),(2,9),(2,10),
    (3,11),(3,12),(3,13),(3,14),(3,15),
    (4,16),(4,2),(4,17),(4,18),
    (5,19),(5,2),(5,3),(5,5);


-- ═════════ USERS DATA (fictional people) ═════════
-- 520 users = 1 System Admin + 1 Management + 1 Staff + 517 Clients; 3 employee_profiles rows.
-- Every account uses the password:  password123
--   msantos@nha.gov.ph = System Admin | taquino@nha.gov.ph = Management | jdelacruz@nha.gov.ph = Staff | pvillanueva@gmail.com = Client

SET NAMES utf8mb4;
START TRANSACTION;

-- users (520 rows)
INSERT INTO users (user_id, role_id, email, password_hash, first_name, middle_name, last_name, phone, is_active, must_change_password, last_login_at, created_at) VALUES
  (1, 1, 'msantos@nha.gov.ph', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Maria', NULL, 'Santos', '09114592947', 1, 0, '2026-10-17 09:30:00', '2026-01-05 09:17:00'),
  (2, 4, 'taquino@nha.gov.ph', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Teresa', NULL, 'Aquino', '09524835064', 1, 0, '2026-10-15 13:30:00', '2026-01-05 09:34:00'),
  (3, 2, 'jdelacruz@nha.gov.ph', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Juan', NULL, 'dela Cruz', '09247389050', 1, 0, '2026-10-15 07:30:00', '2026-01-05 09:51:00'),
  (4, 3, 'pvillanueva@gmail.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Pedro', 'Santos', 'Villanueva', '09104047633', 1, 0, NULL, '2026-07-14 12:54:00'),
  (5, 3, 'cbautista@gmail.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Carmen', NULL, 'Bautista', '09485077775', 1, 0, '2026-10-17 17:30:00', '2026-08-16 15:32:00'),
  (6, 3, 'eramos@gmail.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Eduardo', NULL, 'Ramos', '09536566069', 1, 0, '2026-10-05 12:50:00', '2026-05-20 08:50:00'),
  (7, 3, 'fquizon@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Fernando', NULL, 'Quizon', '09115461402', 1, 0, '2026-10-17 17:30:00', '2026-09-24 10:45:00'),
  (8, 3, 'mebarle@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Merlyn', 'Lopez', 'Ebarle', '09895771523', 1, 0, '2026-10-17 17:30:00', '2026-08-22 17:24:00'),
  (9, 3, 'byap@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Bryan', NULL, 'Yap', '09813549599', 1, 0, '2026-05-27 00:46:00', '2026-05-13 13:46:00'),
  (10, 3, 'idalumpines@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Imelda', 'Garcia', 'Dalumpines', '09551745500', 1, 0, '2026-03-23 03:01:00', '2026-03-22 14:01:00'),
  (11, 3, 'cgaid@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Cristina', 'Estrada', 'Gaid', '09963847200', 1, 0, '2026-07-18 14:01:00', '2026-02-25 12:01:00'),
  (12, 3, 'kcruz@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Kevin', NULL, 'Cruz', '09331915373', 1, 0, '2026-10-17 17:30:00', '2026-09-29 15:51:00'),
  (13, 3, 'ltorres@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Leonardo', NULL, 'Torres', '09320864506', 1, 0, NULL, '2026-01-28 15:08:00'),
  (14, 3, 'cgarcia@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Carlo', NULL, 'Garcia', '09617854909', 1, 0, '2026-08-29 00:49:00', '2026-05-19 17:49:00'),
  (15, 3, 'wtumulak@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Wilfredo', 'Estrada', 'Tumulak', '09163828869', 1, 0, NULL, '2026-05-06 08:42:00'),
  (16, 3, 'rsalazar@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Rowena', 'Evangelista', 'Salazar', '09670166196', 0, 0, '2026-02-12 08:51:00', '2026-02-09 08:51:00'),
  (17, 3, 'rpableo@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Remedios', NULL, 'Pableo', '09216666282', 1, 0, '2026-10-13 16:52:00', '2026-09-02 14:52:00'),
  (18, 3, 'npadilla@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Noel', NULL, 'Padilla', '09375802902', 1, 0, '2026-04-21 10:01:00', '2026-03-21 10:01:00'),
  (19, 3, 'fmacasero@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Felix', NULL, 'Macasero', NULL, 1, 0, '2026-06-13 03:15:00', '2026-02-09 16:15:00'),
  (20, 3, 'vmendoza@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Virgilio', NULL, 'Mendoza', '09180975281', 1, 0, '2026-06-27 23:32:00', '2026-04-29 12:32:00'),
  (21, 3, 'jbacalso@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Jovelyn', 'Lopez', 'Bacalso', '09677042209', 1, 0, '2026-08-06 03:37:00', '2026-04-18 09:37:00'),
  (22, 3, 'dracaza@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Dolores', 'Aquino', 'Racaza', '09882336371', 1, 0, '2026-03-25 12:59:00', '2026-01-17 16:59:00'),
  (23, 3, 'jpadilla@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Jaime', NULL, 'Padilla', '09891649384', 1, 0, '2026-07-23 04:53:00', '2026-05-23 12:53:00'),
  (24, 3, 'dgarcia@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Dennis', 'Santos', 'Garcia', '09921450125', 1, 0, '2026-02-17 02:10:00', '2026-01-23 10:10:00'),
  (25, 3, 'ccastillo@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Corazon', 'Lopez', 'Castillo', '09756429619', 1, 0, '2026-06-02 01:19:00', '2026-03-20 15:19:00'),
  (26, 3, 'jacosta@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Jaime', NULL, 'Acosta', '09456951239', 1, 0, NULL, '2026-05-28 16:55:00'),
  (27, 3, 'cestrada@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Christian', NULL, 'Estrada', '09287510151', 1, 0, NULL, '2026-07-28 11:10:00'),
  (28, 3, 'edomingo@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Elena', NULL, 'Domingo', '09118872814', 1, 0, '2026-10-17 17:30:00', '2026-10-09 15:47:00'),
  (29, 3, 'itabamo@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Imelda', 'Cabrera', 'Tabamo', '09125842658', 1, 0, '2026-08-15 16:58:00', '2026-08-06 13:58:00'),
  (30, 3, 'scruz@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Shiela', 'Pineda', 'Cruz', '09189895689', 1, 0, '2026-06-25 18:36:00', '2026-03-21 09:36:00'),
  (31, 3, 'cybanez@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Cesar', 'Evangelista', 'Ybanez', '09225107745', 1, 0, '2026-09-06 12:43:00', '2026-05-26 08:43:00'),
  (32, 3, 'pflores@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Perla', 'Gutierrez', 'Flores', '09390940060', 1, 0, '2026-10-17 17:30:00', '2026-09-26 13:20:00'),
  (33, 3, 'jdumaguit@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Jasmine', NULL, 'Dumaguit', '09205013176', 1, 0, '2026-08-18 20:09:00', '2026-07-12 10:09:00'),
  (34, 3, 'galonzo@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Gilbert', NULL, 'Alonzo', '09104715863', 1, 0, '2026-07-22 23:57:00', '2026-06-17 08:57:00'),
  (35, 3, 'rcabahug@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Roberto', 'Pineda', 'Cabahug', '09436888438', 1, 0, '2026-03-07 18:53:00', '2026-01-26 13:53:00'),
  (36, 3, 'gracaza@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Gemma', NULL, 'Racaza', '09467237294', 1, 0, '2026-03-16 19:49:00', '2026-01-25 11:49:00'),
  (37, 3, 'nabellanosa@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Nenita', 'Pineda', 'Abellanosa', '09660273126', 1, 0, '2026-09-01 18:38:00', '2026-04-25 17:38:00'),
  (38, 3, 'tpepito@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Teresita', 'Gutierrez', 'Pepito', '09499731992', 1, 0, '2026-06-15 02:02:00', '2026-03-22 08:02:00'),
  (39, 3, 'vvaldez@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Victor', NULL, 'Valdez', '09531336799', 1, 0, '2026-10-17 17:30:00', '2026-09-04 11:56:00'),
  (40, 3, 'lroque@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Lorna', 'Lopez', 'Roque', NULL, 1, 0, '2026-07-25 01:31:00', '2026-04-09 09:31:00'),
  (41, 3, 'buy@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Benjamin', NULL, 'Uy', '09837137552', 1, 0, '2026-06-08 10:03:00', '2026-05-11 09:03:00'),
  (42, 3, 'mrabago@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Mark Anthony', 'Reyes', 'Rabago', '09994418761', 1, 0, '2026-10-17 17:30:00', '2026-09-06 16:46:00'),
  (43, 3, 'rgaid@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Reynaldo', 'Evangelista', 'Gaid', '09244711098', 1, 0, '2026-10-17 17:30:00', '2026-10-06 16:19:00'),
  (44, 3, 'msoriano@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Manuel', NULL, 'Soriano', '09934736559', 1, 0, '2026-04-20 23:21:00', '2026-03-04 16:21:00'),
  (45, 3, 'nracaza@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Norma', 'Pineda', 'Racaza', '09535731118', 1, 0, '2026-10-17 17:30:00', '2026-10-01 12:03:00'),
  (46, 3, 'stumulak@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Sheryl', 'Dizon', 'Tumulak', '09644998626', 1, 0, '2026-06-17 12:29:00', '2026-01-18 08:29:00'),
  (47, 3, 'mocampo@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Manuel', 'Mercado', 'Ocampo', '09782087150', 1, 0, '2026-10-17 17:30:00', '2026-08-27 10:09:00'),
  (48, 3, 'agonzales@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Angelica', 'Mercado', 'Gonzales', '09321018522', 1, 0, '2026-05-08 03:22:00', '2026-03-28 16:22:00'),
  (49, 3, 'bbautista@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Belen', 'Bernardo', 'Bautista', '09697395139', 1, 0, '2026-06-18 13:49:00', '2026-02-20 08:49:00'),
  (50, 3, 'nmagno@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Noel', NULL, 'Magno', '09593162262', 1, 0, '2026-09-24 06:22:00', '2026-06-16 12:22:00');
INSERT INTO users (user_id, role_id, email, password_hash, first_name, middle_name, last_name, phone, is_active, must_change_password, last_login_at, created_at) VALUES
  (51, 3, 'rdalumpines@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Remedios', 'Aquino', 'Dalumpines', '09138817115', 1, 0, '2026-07-27 01:10:00', '2026-04-29 08:10:00'),
  (52, 3, 'gocampo@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Glenda', NULL, 'Ocampo', '09990216433', 1, 0, '2026-09-15 17:48:00', '2026-07-21 14:48:00'),
  (53, 3, 'mgabule@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Mark Anthony', 'Dizon', 'Gabule', '09124817001', 1, 0, NULL, '2026-01-31 11:52:00'),
  (54, 3, 'valonzo@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Vilma', NULL, 'Alonzo', '09997245324', 1, 0, NULL, '2026-10-11 17:41:00'),
  (55, 3, 'ivillareal@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Imelda', NULL, 'Villareal', '09727201502', 1, 0, '2026-09-24 15:11:00', '2026-09-15 14:11:00'),
  (56, 3, 'jfernandez@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Jovelyn', 'Cabrera', 'Fernandez', '09410301230', 1, 0, '2026-10-17 17:30:00', '2026-09-07 12:59:00'),
  (57, 3, 'gcabrera@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Gilbert', 'Cabrera', 'Cabrera', '09159802719', 1, 0, '2026-09-10 06:33:00', '2026-06-24 16:33:00'),
  (58, 3, 'rpepito@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Roberto', NULL, 'Pepito', '09368747743', 1, 0, '2026-10-17 17:30:00', '2026-07-10 12:12:00'),
  (59, 3, 'tramos@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Teresita', 'Mercado', 'Ramos', '09355653703', 1, 0, '2026-07-30 10:40:00', '2026-03-28 10:40:00'),
  (60, 3, 'egarcia@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Estrella', 'Evangelista', 'Garcia', '09841387616', 1, 0, '2026-06-14 05:47:00', '2026-03-24 09:47:00'),
  (61, 3, 'llagrosas@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Lea', 'Gutierrez', 'Lagrosas', '09233278054', 1, 0, '2026-06-02 20:19:00', '2026-05-28 08:19:00'),
  (62, 3, 'igaid@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Ignacio', NULL, 'Gaid', '09693349948', 1, 0, '2026-06-18 04:52:00', '2026-02-20 10:52:00'),
  (63, 3, 'nmercado@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Noel', NULL, 'Mercado', '09124678183', 1, 0, NULL, '2026-03-30 13:11:00'),
  (64, 3, 'rtorres@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Roberto', NULL, 'Torres', '09799891267', 1, 0, '2026-09-17 06:10:00', '2026-06-11 17:10:00'),
  (65, 3, 'mfernandez@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Mary Grace', 'Pineda', 'Fernandez', '09162716513', 1, 0, '2026-10-17 17:30:00', '2026-09-04 10:43:00'),
  (66, 3, 'spepito@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Samuel', 'Estrada', 'Pepito', NULL, 1, 0, '2026-09-11 15:52:00', '2026-07-16 09:52:00'),
  (67, 3, 'atan@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Arturo', 'Aquino', 'Tan', '09684433105', 1, 0, '2026-08-30 21:56:00', '2026-04-15 11:56:00'),
  (68, 3, 'cdomingo@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Cesar', 'Evangelista', 'Domingo', '09635846038', 1, 0, NULL, '2026-03-22 09:23:00'),
  (69, 3, 'nroque@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Norma', 'Pineda', 'Roque', '09790437129', 1, 0, '2026-10-17 17:30:00', '2026-10-02 11:44:00'),
  (70, 3, 'aabellanosa@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Alfredo', NULL, 'Abellanosa', '09833527444', 1, 0, '2026-07-14 10:29:00', '2026-06-04 16:29:00'),
  (71, 3, 'hfernandez@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Herminio', 'Cabrera', 'Fernandez', '09363497017', 1, 0, '2026-10-17 17:30:00', '2026-08-18 15:17:00'),
  (72, 3, 'mestrada@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Mary Grace', NULL, 'Estrada', '09108810301', 1, 0, '2026-07-09 16:26:00', '2026-04-15 12:26:00'),
  (73, 3, 'ndumaguit@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Noel', NULL, 'Dumaguit', '09645015794', 1, 0, '2026-10-17 17:30:00', '2026-07-04 11:56:00'),
  (74, 3, 'westrada@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Wilma', NULL, 'Estrada', '09696252983', 1, 0, '2026-03-05 01:52:00', '2026-02-04 14:52:00'),
  (75, 3, 'hcastillo@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Herminio', 'Bernardo', 'Castillo', '09314121241', 1, 0, '2026-03-17 03:48:00', '2026-02-11 09:48:00'),
  (76, 3, 'nflores@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Norma', 'Bernardo', 'Flores', '09276771294', 1, 0, '2026-03-31 13:21:00', '2026-03-26 10:21:00'),
  (77, 3, 'jsia@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Jessie', NULL, 'Sia', NULL, 1, 0, '2026-08-14 23:28:00', '2026-06-17 11:28:00'),
  (78, 3, 'jebarle@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Jessie', 'Mercado', 'Ebarle', NULL, 1, 0, NULL, '2026-09-30 10:36:00'),
  (79, 3, 'rpadilla@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Remedios', 'Pineda', 'Padilla', '09198073614', 1, 0, '2026-07-01 08:31:00', '2026-04-08 13:31:00'),
  (80, 3, 'oocampo@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Orlando', 'Gutierrez', 'Ocampo', NULL, 1, 0, '2026-05-12 15:36:00', '2026-02-13 10:36:00'),
  (81, 3, 'aacosta@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Antonio', 'Santos', 'Acosta', '09831819316', 1, 0, '2026-05-25 19:55:00', '2026-04-22 08:55:00'),
  (82, 3, 'esalazar@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Elena', 'Evangelista', 'Salazar', '09531710482', 1, 0, NULL, '2026-01-22 16:19:00'),
  (83, 3, 'msantos@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Mark Anthony', 'Aquino', 'Santos', '09884989649', 1, 0, '2026-09-17 16:31:00', '2026-08-30 16:31:00'),
  (84, 3, 'rlagrosas@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Rogelio', NULL, 'Lagrosas', '09784570488', 1, 0, '2026-09-23 00:54:00', '2026-04-30 17:54:00'),
  (85, 3, 'bbacalso@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Bryan', NULL, 'Bacalso', '09284189021', 1, 0, '2026-06-26 05:06:00', '2026-02-08 15:06:00'),
  (86, 3, 'cmercado@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Christian', 'Bernardo', 'Mercado', '09123118781', 1, 0, '2026-03-31 10:29:00', '2026-01-17 17:29:00'),
  (87, 3, 'isumalinog@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Ivy', 'Bernardo', 'Sumalinog', '09946499632', 1, 0, '2026-03-13 06:19:00', '2026-02-12 16:19:00'),
  (88, 3, 'srabago@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Sheryl', 'Aquino', 'Rabago', '09859819748', 1, 0, '2026-05-03 09:52:00', '2026-05-02 13:52:00'),
  (89, 3, 'dpableo@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Dolores', 'Corpuz', 'Pableo', NULL, 1, 0, '2026-03-09 02:18:00', '2026-02-04 15:18:00'),
  (90, 3, 'jyap@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Joy', NULL, 'Yap', '09867578818', 1, 0, '2026-07-06 15:45:00', '2026-03-01 11:45:00'),
  (91, 3, 'vcabahug@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Victor', 'Pineda', 'Cabahug', '09371123312', 1, 0, '2026-08-15 18:06:00', '2026-07-03 17:06:00'),
  (92, 3, 'npadilla2@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Nelson', NULL, 'Padilla', '09939012416', 1, 0, '2026-09-23 11:57:00', '2026-05-12 09:57:00'),
  (93, 3, 'stan@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Shiela', 'Mercado', 'Tan', NULL, 1, 0, NULL, '2026-08-14 15:06:00'),
  (94, 3, 'mrabago2@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Manuel', 'Dizon', 'Rabago', '09742545078', 1, 0, '2026-09-28 03:55:00', '2026-06-26 16:55:00'),
  (95, 3, 'nlim@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Nestor', 'Mercado', 'Lim', '09459308958', 1, 0, '2026-09-10 17:51:00', '2026-08-12 09:51:00'),
  (96, 3, 'rfernandez@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Rodel', 'Bernardo', 'Fernandez', '09439095612', 1, 0, '2026-07-26 20:34:00', '2026-04-11 08:34:00'),
  (97, 3, 'jgarcia@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Jennifer', 'Pineda', 'Garcia', '09114090149', 1, 0, '2026-08-28 16:06:00', '2026-08-12 10:06:00'),
  (98, 3, 'kramos@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Karen', NULL, 'Ramos', '09797882151', 1, 0, '2026-08-21 03:57:00', '2026-06-20 10:57:00'),
  (99, 3, 'rquizon@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Remedios', 'Gutierrez', 'Quizon', '09562195719', 1, 0, '2026-07-06 04:26:00', '2026-05-02 17:26:00'),
  (100, 3, 'cvaldez@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Cesar', 'Bernardo', 'Valdez', '09463540226', 1, 0, '2026-10-03 05:28:00', '2026-07-23 14:28:00');
INSERT INTO users (user_id, role_id, email, password_hash, first_name, middle_name, last_name, phone, is_active, must_change_password, last_login_at, created_at) VALUES
  (101, 3, 'mlopez@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Marites', NULL, 'Lopez', '09112862625', 1, 0, '2026-06-20 11:31:00', '2026-01-26 17:31:00'),
  (102, 3, 'mtorres@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Merlyn', 'Estrada', 'Torres', '09757671090', 1, 0, '2026-10-17 17:30:00', '2026-07-21 13:02:00'),
  (103, 3, 'ldalumpines@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Lourdes', 'Garcia', 'Dalumpines', '09675092955', 1, 0, '2026-10-17 17:30:00', '2026-09-07 14:19:00'),
  (104, 3, 'vacosta@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Virgilio', 'Lopez', 'Acosta', '09957682767', 1, 0, '2026-06-28 15:16:00', '2026-02-23 11:16:00'),
  (105, 3, 'jrivera@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Jovelyn', 'Reyes', 'Rivera', '09151612353', 1, 0, '2026-10-17 17:30:00', '2026-08-01 16:22:00'),
  (106, 3, 'rbacalso@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Rodel', 'Mercado', 'Bacalso', '09595196263', 1, 0, '2026-10-17 17:30:00', '2026-09-02 11:49:00'),
  (107, 3, 'jpepito@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Jaime', 'Evangelista', 'Pepito', '09102935334', 1, 0, '2026-10-17 17:30:00', '2026-08-19 12:43:00'),
  (108, 3, 'rabellanosa@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Rica', 'Aquino', 'Abellanosa', '09610365319', 1, 0, '2026-07-04 20:44:00', '2026-06-07 12:44:00'),
  (109, 3, 'mtan@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Mark Anthony', NULL, 'Tan', '09452914915', 1, 0, '2026-07-11 13:41:00', '2026-07-09 08:41:00'),
  (110, 3, 'ftumulak@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Fernando', 'Dizon', 'Tumulak', '09696267282', 1, 0, '2026-10-17 17:30:00', '2026-08-11 14:27:00'),
  (111, 3, 'gybanez@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Gilbert', NULL, 'Ybanez', '09617394996', 1, 0, '2026-10-17 17:30:00', '2026-07-23 12:24:00'),
  (112, 3, 'mtabamo@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Manuel', NULL, 'Tabamo', '09944979504', 1, 0, '2026-10-17 17:30:00', '2026-09-26 09:20:00'),
  (113, 3, 'csia@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Cesar', 'Gutierrez', 'Sia', '09853457840', 1, 0, '2026-10-17 17:30:00', '2026-08-31 13:20:00'),
  (114, 3, 'lramos@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Lito', NULL, 'Ramos', '09974540781', 1, 0, '2026-09-06 22:07:00', '2026-08-23 08:07:00'),
  (115, 3, 'nlim2@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Nenita', 'Mercado', 'Lim', '09239588747', 1, 0, '2026-05-09 10:05:00', '2026-03-16 08:05:00'),
  (116, 3, 'abautista@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Antonio', 'Aquino', 'Bautista', '09348067207', 1, 0, NULL, '2026-07-25 08:08:00'),
  (117, 3, 'rtan@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Rowena', NULL, 'Tan', '09560833648', 1, 0, '2026-06-02 04:15:00', '2026-01-25 13:15:00'),
  (118, 3, 'olopez@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Orlando', 'Gutierrez', 'Lopez', NULL, 1, 0, '2026-07-20 18:03:00', '2026-06-25 12:03:00'),
  (119, 3, 'cbacalso@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Catherine', 'Lopez', 'Bacalso', NULL, 1, 0, '2026-08-03 04:37:00', '2026-03-15 14:37:00'),
  (120, 3, 'jdumaguit2@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Jose', 'Santos', 'Dumaguit', '09981304884', 1, 0, '2026-05-07 23:29:00', '2026-05-05 09:29:00'),
  (121, 3, 'snavarro@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Shiela', NULL, 'Navarro', '09952600554', 1, 0, '2026-08-27 12:07:00', '2026-05-19 17:07:00'),
  (122, 3, 'rvaldez@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Rogelio', 'Santos', 'Valdez', '09342207123', 1, 0, '2026-10-17 17:30:00', '2026-07-01 10:59:00'),
  (123, 3, 'aflores@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Ana', NULL, 'Flores', '09833525961', 1, 0, '2026-06-01 06:46:00', '2026-01-23 14:46:00'),
  (124, 3, 'mmercado@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Mark Anthony', NULL, 'Mercado', NULL, 1, 0, '2026-09-08 12:59:00', '2026-06-08 08:59:00'),
  (125, 3, 'bpadilla@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Bryan', NULL, 'Padilla', '09175220212', 1, 0, '2026-10-17 17:30:00', '2026-08-19 16:24:00'),
  (126, 3, 'avillareal@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Arturo', NULL, 'Villareal', '09891656719', 1, 0, '2026-05-29 13:40:00', '2026-03-20 08:40:00'),
  (127, 3, 'oquizon@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Ofelia', 'Dizon', 'Quizon', '09695724108', 1, 0, '2026-07-19 08:56:00', '2026-06-12 12:56:00'),
  (128, 3, 'orabago@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Ofelia', 'Lopez', 'Rabago', '09991846935', 0, 0, '2026-05-14 02:17:00', '2026-02-03 16:17:00'),
  (129, 3, 'rroque@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Rogelio', NULL, 'Roque', '09566454027', 1, 0, '2026-07-30 16:43:00', '2026-05-22 11:43:00'),
  (130, 3, 'auy@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Arturo', 'Reyes', 'Uy', '09433658460', 1, 0, '2026-09-18 05:58:00', '2026-05-13 17:58:00'),
  (131, 3, 'mcabahug@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Manuel', 'Santos', 'Cabahug', NULL, 1, 0, '2026-04-16 03:55:00', '2026-02-16 12:55:00'),
  (132, 3, 'achavez@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Alvin', NULL, 'Chavez', '09278512790', 1, 0, '2026-07-13 13:58:00', '2026-06-18 08:58:00'),
  (133, 3, 'frivera@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Fernando', 'Lopez', 'Rivera', '09631032970', 1, 0, NULL, '2026-07-24 09:11:00'),
  (134, 3, 'ntan@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Nelson', 'Garcia', 'Tan', '09475541614', 1, 0, '2026-07-04 05:25:00', '2026-04-14 17:25:00'),
  (135, 3, 'lflores@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Lourdes', 'Corpuz', 'Flores', '09843230775', 0, 0, '2026-05-24 17:12:00', '2026-03-08 15:12:00'),
  (136, 3, 'dnavarro@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Divina', NULL, 'Navarro', '09126302222', 1, 0, '2026-10-17 17:30:00', '2026-09-06 14:32:00'),
  (137, 3, 'lcabrera@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Lourdes', 'Gutierrez', 'Cabrera', '09148787855', 1, 0, '2026-07-10 23:08:00', '2026-06-14 11:08:00'),
  (138, 3, 'tpepito2@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Tessie', 'Estrada', 'Pepito', '09986949722', 1, 0, '2026-07-31 23:03:00', '2026-07-23 17:03:00'),
  (139, 3, 'abacalso@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Alvin', NULL, 'Bacalso', '09120508431', 1, 0, '2026-03-23 02:17:00', '2026-02-04 11:17:00'),
  (140, 3, 'aacosta2@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Ana', NULL, 'Acosta', '09189855023', 1, 0, '2026-08-09 22:31:00', '2026-06-05 12:31:00'),
  (141, 3, 'rrabago@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Rowena', 'Mercado', 'Rabago', '09412702204', 1, 0, NULL, '2026-09-02 17:12:00'),
  (142, 3, 'jsumalinog@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Joy', 'Santos', 'Sumalinog', '09988880166', 1, 0, '2026-04-06 10:13:00', '2026-03-24 10:13:00'),
  (143, 3, 'dparaiso@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Dennis', 'Lopez', 'Paraiso', '09147184345', 1, 0, '2026-10-17 17:30:00', '2026-07-29 09:30:00'),
  (144, 3, 'naguilar@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Norma', 'Mercado', 'Aguilar', '09776915735', 1, 0, '2026-10-17 17:30:00', '2026-06-02 13:30:00'),
  (145, 3, 'ecruz@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Estrella', 'Mercado', 'Cruz', '09368677735', 1, 0, '2026-05-04 02:49:00', '2026-04-04 08:49:00'),
  (146, 3, 'sflores@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Sheryl', 'Estrada', 'Flores', '09793503746', 1, 0, '2026-04-29 01:10:00', '2026-03-30 09:10:00'),
  (147, 3, 'ddalumpines@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Dante', NULL, 'Dalumpines', '09880795210', 1, 0, '2026-09-15 15:52:00', '2026-06-09 13:52:00'),
  (148, 3, 'bcruz@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Bernard', 'Aquino', 'Cruz', '09103883962', 1, 0, '2026-04-22 18:33:00', '2026-02-12 15:33:00'),
  (149, 3, 'puy@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Perla', 'Corpuz', 'Uy', '09607493534', 1, 0, '2026-06-28 17:00:00', '2026-05-14 15:00:00'),
  (150, 3, 'bdomingo@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Belen', 'Evangelista', 'Domingo', '09480429555', 1, 0, '2026-05-10 00:58:00', '2026-01-22 08:58:00');
INSERT INTO users (user_id, role_id, email, password_hash, first_name, middle_name, last_name, phone, is_active, must_change_password, last_login_at, created_at) VALUES
  (151, 3, 'ctabamo@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Cesar', 'Cabrera', 'Tabamo', '09963830951', 1, 0, '2026-10-17 17:30:00', '2026-08-06 11:31:00'),
  (152, 3, 'anavarro@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Ana', NULL, 'Navarro', NULL, 1, 0, '2026-08-16 18:33:00', '2026-06-20 11:33:00'),
  (153, 3, 'rdumaguit@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Rodel', 'Reyes', 'Dumaguit', '09681450585', 1, 0, '2026-06-30 22:15:00', '2026-06-17 08:15:00'),
  (154, 3, 'egaid@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Ernesto', NULL, 'Gaid', '09456758351', 1, 0, '2026-06-30 08:48:00', '2026-03-30 08:48:00'),
  (155, 3, 'areyes@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Angelica', 'Mercado', 'Reyes', '09890740087', 1, 0, '2026-07-20 15:58:00', '2026-04-11 11:58:00'),
  (156, 3, 'aebarle@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Arturo', 'Santos', 'Ebarle', '09352342146', 1, 0, '2026-09-03 03:33:00', '2026-06-01 17:33:00'),
  (157, 3, 'dreyes@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Dennis', NULL, 'Reyes', '09544379507', 1, 0, '2026-07-11 12:55:00', '2026-05-08 17:55:00'),
  (158, 3, 'ddomingo@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Dante', 'Lopez', 'Domingo', '09153050995', 1, 0, '2026-06-25 11:13:00', '2026-04-21 15:13:00'),
  (159, 3, 'restrada@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Rodrigo', 'Gutierrez', 'Estrada', '09410448078', 1, 0, '2026-10-17 17:30:00', '2026-09-30 17:45:00'),
  (160, 3, 'lmendoza@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Lea', 'Estrada', 'Mendoza', '09216449542', 1, 0, NULL, '2026-01-14 09:22:00'),
  (161, 3, 'adelacruz@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Angelica', 'Gutierrez', 'dela Cruz', '09186189267', 1, 0, '2026-07-09 02:55:00', '2026-04-24 10:55:00'),
  (162, 3, 'igonzales@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Ignacio', NULL, 'Gonzales', '09504431900', 1, 0, '2026-09-21 04:04:00', '2026-06-10 15:04:00'),
  (163, 3, 'psia@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Pedro', 'Garcia', 'Sia', '09501052483', 1, 0, NULL, '2026-08-31 17:43:00'),
  (164, 3, 'scruz2@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Samuel', NULL, 'Cruz', '09602979459', 1, 0, '2026-07-19 02:22:00', '2026-03-28 16:22:00'),
  (165, 3, 'bmacasero@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Bryan', 'Aquino', 'Macasero', NULL, 1, 0, '2026-03-25 18:54:00', '2026-03-20 14:54:00'),
  (166, 3, 'jbautista@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Jerome', 'Dizon', 'Bautista', '09718336837', 1, 0, '2026-10-05 08:41:00', '2026-09-21 16:41:00'),
  (167, 3, 'ocruz@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Oscar', NULL, 'Cruz', '09147291816', 1, 0, '2026-10-17 17:30:00', '2026-09-01 14:10:00'),
  (168, 3, 'vdalumpines@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Victor', NULL, 'Dalumpines', '09868566272', 1, 0, '2026-10-17 17:30:00', '2026-09-06 17:42:00'),
  (169, 3, 'mcabrera@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Marites', 'Corpuz', 'Cabrera', '09912280673', 1, 0, '2026-05-15 07:29:00', '2026-02-22 15:29:00'),
  (170, 3, 'mflores@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Michelle', NULL, 'Flores', NULL, 0, 0, '2026-06-18 23:30:00', '2026-06-03 08:30:00'),
  (171, 3, 'mlim@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Mildred', 'Santos', 'Lim', '09858071191', 1, 0, '2026-04-15 22:57:00', '2026-01-27 08:57:00'),
  (172, 3, 'ssantos@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Sheryl', 'Aquino', 'Santos', '09149647821', 1, 0, '2026-06-07 01:02:00', '2026-03-20 17:02:00'),
  (173, 3, 'ggonzales@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Gregorio', 'Evangelista', 'Gonzales', '09265076363', 1, 0, '2026-06-05 05:14:00', '2026-05-17 16:14:00'),
  (174, 3, 'mtan2@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Mary Grace', 'Cabrera', 'Tan', '09648088505', 1, 0, '2026-07-02 11:02:00', '2026-02-18 08:02:00'),
  (175, 3, 'kuy@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Kevin', NULL, 'Uy', '09849247518', 1, 0, '2026-05-07 04:34:00', '2026-03-05 14:34:00'),
  (176, 3, 'cgabule@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Catherine', 'Evangelista', 'Gabule', '09673794495', 1, 0, '2026-09-06 22:47:00', '2026-07-28 09:47:00'),
  (177, 3, 'oparaiso@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Oscar', NULL, 'Paraiso', '09966183024', 0, 0, '2026-03-09 10:46:00', '2026-01-25 09:46:00'),
  (178, 3, 'jramos@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Jaime', NULL, 'Ramos', '09332566013', 1, 0, '2026-06-16 18:39:00', '2026-01-23 12:39:00'),
  (179, 3, 'ivaldez@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Ignacio', 'Evangelista', 'Valdez', '09213847968', 1, 0, '2026-08-29 19:25:00', '2026-04-29 15:25:00'),
  (180, 3, 'macosta@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Mark Anthony', 'Garcia', 'Acosta', NULL, 1, 0, '2026-10-17 17:30:00', '2026-09-16 10:48:00'),
  (181, 3, 'grivera@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Gregorio', 'Santos', 'Rivera', '09979559350', 1, 0, '2026-09-14 22:39:00', '2026-05-29 10:39:00'),
  (182, 3, 'juy@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Jasmine', 'Corpuz', 'Uy', '09407724699', 1, 0, '2026-10-17 17:30:00', '2026-08-28 08:53:00'),
  (183, 3, 'aflores2@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Alvin', NULL, 'Flores', '09932630840', 1, 0, '2026-08-06 09:59:00', '2026-03-26 17:59:00'),
  (184, 3, 'wfernandez@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Wilfredo', 'Corpuz', 'Fernandez', '09490780686', 1, 0, '2026-04-06 15:41:00', '2026-01-12 08:41:00'),
  (185, 3, 'cgabule2@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Corazon', 'Santos', 'Gabule', '09347733922', 1, 0, '2026-04-28 23:29:00', '2026-03-09 12:29:00'),
  (186, 3, 'cparaiso@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Cesar', NULL, 'Paraiso', '09595761065', 1, 0, '2026-10-17 17:30:00', '2026-09-25 13:00:00'),
  (187, 3, 'csalazar@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Corazon', 'Pineda', 'Salazar', '09166443115', 1, 0, '2026-08-05 10:47:00', '2026-04-18 17:47:00'),
  (188, 3, 'jcabahug@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Jasmine', 'Corpuz', 'Cabahug', '09190103198', 1, 0, '2026-10-09 21:31:00', '2026-06-29 16:31:00'),
  (189, 3, 'lsumalinog@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Lito', 'Gutierrez', 'Sumalinog', '09269169732', 1, 0, '2026-01-29 19:17:00', '2026-01-26 12:17:00'),
  (190, 3, 'btumulak@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Benjamin', NULL, 'Tumulak', '09653715890', 1, 0, '2026-07-16 11:06:00', '2026-03-24 16:06:00'),
  (191, 3, 'icabrera@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Irene', NULL, 'Cabrera', '09582091106', 1, 0, '2026-04-29 21:20:00', '2026-03-31 16:20:00'),
  (192, 3, 'febarle@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Fe', 'Reyes', 'Ebarle', '09779279978', 0, 0, '2026-07-09 04:28:00', '2026-06-16 09:28:00'),
  (193, 3, 'ncabrera@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Nestor', NULL, 'Cabrera', '09615648231', 1, 0, '2026-09-22 01:30:00', '2026-05-16 15:30:00'),
  (194, 3, 'dsia@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Dolores', 'Garcia', 'Sia', '09214748780', 1, 0, '2026-10-17 17:30:00', '2026-10-10 15:40:00'),
  (195, 3, 'tgaid@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Tessie', 'Bernardo', 'Gaid', '09482335049', 1, 0, '2026-10-17 17:30:00', '2026-07-30 09:10:00'),
  (196, 3, 'lsumalinog2@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Lourdes', NULL, 'Sumalinog', '09431775875', 1, 0, '2026-10-17 17:30:00', '2026-09-28 14:31:00'),
  (197, 3, 'mtan3@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Mildred', NULL, 'Tan', '09547012206', 1, 0, '2026-07-22 07:00:00', '2026-04-17 15:00:00'),
  (198, 3, 'vtorres@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Vilma', NULL, 'Torres', '09868375689', 1, 0, '2026-10-17 17:30:00', '2026-09-09 16:19:00'),
  (199, 3, 'jlim@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Jose', 'Evangelista', 'Lim', NULL, 1, 0, '2026-09-18 18:57:00', '2026-09-13 08:57:00'),
  (200, 3, 'wmendoza@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Wilma', 'Pineda', 'Mendoza', '09313461191', 1, 0, '2026-08-20 02:04:00', '2026-06-11 13:04:00');
INSERT INTO users (user_id, role_id, email, password_hash, first_name, middle_name, last_name, phone, is_active, must_change_password, last_login_at, created_at) VALUES
  (201, 3, 'vvillareal@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Victor', NULL, 'Villareal', '09447876375', 1, 0, '2026-10-17 17:30:00', '2026-09-21 08:31:00'),
  (202, 3, 'testrada@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Teresita', 'Aquino', 'Estrada', '09229599175', 1, 0, '2026-09-09 21:37:00', '2026-05-22 17:37:00'),
  (203, 3, 'dnapoles@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Dennis', NULL, 'Napoles', '09180080527', 1, 0, '2026-08-15 21:23:00', '2026-03-20 14:23:00'),
  (204, 3, 'dcabrera@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Dennis', 'Cabrera', 'Cabrera', '09142164473', 1, 0, '2026-08-02 02:41:00', '2026-03-28 13:41:00'),
  (205, 3, 'evillareal@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Emmanuel', 'Cabrera', 'Villareal', '09627607065', 1, 0, '2026-08-08 15:09:00', '2026-04-30 14:09:00'),
  (206, 3, 'kgaid@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Kevin', 'Corpuz', 'Gaid', '09660014843', 1, 0, '2026-10-17 17:30:00', '2026-09-24 09:30:00'),
  (207, 3, 'edelacruz@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Elena', 'Reyes', 'dela Cruz', '09677754980', 1, 0, '2026-10-17 17:30:00', '2026-09-13 12:04:00'),
  (208, 3, 'sgonzales@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Sheryl', 'Evangelista', 'Gonzales', NULL, 1, 0, '2026-10-13 02:17:00', '2026-09-12 11:17:00'),
  (209, 3, 'nestrada@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Norma', 'Lopez', 'Estrada', '09957372044', 1, 0, '2026-08-14 19:53:00', '2026-06-02 10:53:00'),
  (210, 3, 'kcastillo@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Kevin', 'Lopez', 'Castillo', '09862620083', 1, 0, NULL, '2026-05-29 17:29:00'),
  (211, 3, 'sgaid@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Samuel', 'Reyes', 'Gaid', '09174895609', 1, 0, '2026-08-12 15:17:00', '2026-05-16 09:17:00'),
  (212, 3, 'mlagrosas@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Michelle', 'Corpuz', 'Lagrosas', '09898680601', 1, 0, NULL, '2026-10-03 09:16:00'),
  (213, 3, 'egarcia2@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Emmanuel', 'Gutierrez', 'Garcia', '09119120602', 1, 0, '2026-03-20 17:34:00', '2026-03-02 13:34:00'),
  (214, 3, 'aflores3@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Alfredo', 'Estrada', 'Flores', '09244795123', 1, 0, '2026-09-09 02:20:00', '2026-04-29 08:20:00'),
  (215, 3, 'htan@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Herminio', 'Estrada', 'Tan', '09741493618', 1, 0, NULL, '2026-04-17 09:30:00'),
  (216, 3, 'ftumulak2@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Fe', 'Estrada', 'Tumulak', '09349419163', 1, 0, '2026-10-17 17:30:00', '2026-06-04 14:55:00'),
  (217, 3, 'tpepito3@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Tomas', NULL, 'Pepito', NULL, 1, 0, '2026-09-25 03:17:00', '2026-08-05 15:17:00'),
  (218, 3, 'csalazar2@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Christian', 'Pineda', 'Salazar', '09794407602', 1, 0, '2026-07-26 04:53:00', '2026-04-10 09:53:00'),
  (219, 3, 'jmercado@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Jerome', 'Aquino', 'Mercado', '09462054244', 1, 0, '2026-10-17 17:30:00', '2026-10-06 08:33:00'),
  (220, 3, 'malonzo@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Mildred', 'Dizon', 'Alonzo', '09512205503', 1, 0, NULL, '2026-05-05 12:20:00'),
  (221, 3, 'ebacalso@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Ernesto', 'Aquino', 'Bacalso', '09949389989', 1, 0, NULL, '2026-09-20 10:08:00'),
  (222, 3, 'amaranon@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Antonio', 'Lopez', 'Maranon', '09753853419', 1, 0, '2026-10-17 17:30:00', '2026-08-20 16:20:00'),
  (223, 3, 'dcruz@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Dennis', 'Estrada', 'Cruz', '09147609511', 1, 0, '2026-10-16 04:22:00', '2026-05-30 10:22:00'),
  (224, 3, 'aestrada@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Alfredo', 'Estrada', 'Estrada', '09827723885', 1, 0, NULL, '2026-03-24 12:26:00'),
  (225, 3, 'vlagrosas@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Virgilio', 'Garcia', 'Lagrosas', '09328493241', 1, 0, '2026-10-17 17:30:00', '2026-10-04 08:07:00'),
  (226, 3, 'wvillareal@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Wilma', 'Dizon', 'Villareal', '09145264561', 1, 0, '2026-09-19 02:50:00', '2026-07-20 15:50:00'),
  (227, 3, 'schavez@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Salvador', 'Bernardo', 'Chavez', '09170696741', 1, 0, '2026-09-25 17:02:00', '2026-08-22 16:02:00'),
  (228, 3, 'nuy@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Noel', 'Gutierrez', 'Uy', NULL, 1, 0, NULL, '2026-09-22 13:52:00'),
  (229, 3, 'achavez2@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Arturo', NULL, 'Chavez', '09378326248', 1, 0, '2026-05-15 22:13:00', '2026-05-04 08:13:00'),
  (230, 3, 'dlim@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Divina', 'Garcia', 'Lim', '09936245316', 1, 0, '2026-10-17 17:30:00', '2026-09-05 16:37:00'),
  (231, 3, 'rvillareal@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Ricardo', 'Mercado', 'Villareal', '09233271891', 1, 0, '2026-07-18 21:46:00', '2026-04-18 11:46:00'),
  (232, 3, 'aparaiso@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Aileen', NULL, 'Paraiso', '09537217412', 1, 0, '2026-09-06 08:50:00', '2026-06-25 16:50:00'),
  (233, 3, 'adumaguit@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Ana', 'Bernardo', 'Dumaguit', '09587701089', 1, 0, '2026-05-07 13:13:00', '2026-01-30 08:13:00'),
  (234, 3, 'lmagno@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Lito', 'Cabrera', 'Magno', '09119481394', 1, 0, '2026-03-04 17:24:00', '2026-01-12 14:24:00'),
  (235, 3, 'csantos@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Carlo', 'Corpuz', 'Santos', '09231674817', 1, 0, '2026-10-17 17:30:00', '2026-07-08 10:04:00'),
  (236, 3, 'gmagno@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Gemma', 'Estrada', 'Magno', '09375898949', 1, 0, '2026-07-13 03:35:00', '2026-06-28 11:35:00'),
  (237, 3, 'jybanez@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Jessie', 'Cabrera', 'Ybanez', '09613577145', 1, 0, '2026-03-04 01:06:00', '2026-01-18 08:06:00'),
  (238, 3, 'rrivera@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Rodel', 'Dizon', 'Rivera', '09114558515', 1, 0, '2026-09-20 23:16:00', '2026-07-29 13:16:00'),
  (239, 3, 'gbacalso@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Gregorio', NULL, 'Bacalso', '09936657157', 1, 0, '2026-08-17 18:57:00', '2026-08-15 15:57:00'),
  (240, 3, 'dmercado@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Divina', NULL, 'Mercado', '09716200169', 1, 0, NULL, '2026-08-13 09:17:00'),
  (241, 3, 'asalazar@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Antonio', NULL, 'Salazar', '09321327986', 1, 0, '2026-08-09 06:48:00', '2026-08-06 16:48:00'),
  (242, 3, 'nracaza2@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Nestor', 'Aquino', 'Racaza', '09434323257', 1, 0, '2026-05-17 18:30:00', '2026-04-11 16:30:00'),
  (243, 3, 'vmendoza2@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Vilma', 'Pineda', 'Mendoza', '09614226107', 1, 0, '2026-08-09 20:12:00', '2026-05-02 08:12:00'),
  (244, 3, 'lpacana@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Lorna', 'Santos', 'Pacana', '09617070145', 1, 0, '2026-10-17 17:30:00', '2026-10-03 08:24:00'),
  (245, 3, 'dramos@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Dennis', NULL, 'Ramos', '09910606359', 1, 0, '2026-04-16 23:51:00', '2026-02-08 13:51:00'),
  (246, 3, 'sdomingo@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Salvador', NULL, 'Domingo', '09167655834', 1, 0, '2026-10-16 01:15:00', '2026-09-20 16:15:00'),
  (247, 3, 'mmaranon@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Michelle', NULL, 'Maranon', '09626129397', 1, 0, '2026-07-31 06:35:00', '2026-06-11 11:35:00'),
  (248, 3, 'ppableo@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Precious', 'Corpuz', 'Pableo', '09404991481', 1, 0, '2026-10-17 17:30:00', '2026-08-29 17:03:00'),
  (249, 3, 'rparaiso@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Romeo', 'Mercado', 'Paraiso', '09144196642', 1, 0, '2026-06-15 20:37:00', '2026-04-21 17:37:00'),
  (250, 3, 'westrada2@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Wilfredo', 'Pineda', 'Estrada', '09351939851', 1, 0, '2026-10-17 17:30:00', '2026-08-02 17:11:00');
INSERT INTO users (user_id, role_id, email, password_hash, first_name, middle_name, last_name, phone, is_active, must_change_password, last_login_at, created_at) VALUES
  (251, 3, 'psia2@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Perla', 'Bernardo', 'Sia', '09894945095', 1, 0, '2026-10-17 17:30:00', '2026-08-28 10:11:00'),
  (252, 3, 'vdumaguit@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Virgilio', 'Evangelista', 'Dumaguit', '09144573686', 1, 0, NULL, '2026-07-15 14:26:00'),
  (253, 3, 'cbautista@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Carlo', 'Mercado', 'Bautista', NULL, 1, 0, '2026-06-29 16:23:00', '2026-02-12 15:23:00'),
  (254, 3, 'emagno@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Emmanuel', 'Reyes', 'Magno', '09529233398', 1, 0, '2026-08-19 03:13:00', '2026-03-21 16:13:00'),
  (255, 3, 'jreyes@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Jerome', 'Lopez', 'Reyes', '09278074857', 1, 0, NULL, '2026-05-29 10:40:00'),
  (256, 3, 'mbacalso@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Michelle', NULL, 'Bacalso', '09353414883', 1, 0, '2026-09-06 12:05:00', '2026-05-12 12:05:00'),
  (257, 3, 'rtabamo@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Rosario', NULL, 'Tabamo', '09565488016', 1, 0, '2026-06-16 23:51:00', '2026-03-11 09:51:00'),
  (258, 3, 'nyap@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Nenita', NULL, 'Yap', '09295448065', 1, 0, NULL, '2026-03-05 13:38:00'),
  (259, 3, 'oebarle@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Ofelia', NULL, 'Ebarle', '09953610210', 1, 0, '2026-06-18 02:02:00', '2026-03-03 08:02:00'),
  (260, 3, 'gpepito@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Gerardo', 'Reyes', 'Pepito', '09361700981', 1, 0, '2026-09-18 20:06:00', '2026-05-21 17:06:00'),
  (261, 3, 'aestrada2@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Ana', NULL, 'Estrada', '09156083313', 1, 0, '2026-08-05 02:56:00', '2026-05-08 14:56:00'),
  (262, 3, 'inapoles@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Ivy', NULL, 'Napoles', '09194563181', 0, 0, '2026-10-17 17:30:00', '2026-07-19 08:14:00'),
  (263, 3, 'abacalso2@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Arturo', NULL, 'Bacalso', NULL, 1, 0, '2026-06-09 01:59:00', '2026-04-15 15:59:00'),
  (264, 3, 'cacosta@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Corazon', NULL, 'Acosta', '09733023272', 1, 0, '2026-06-23 03:09:00', '2026-02-22 14:09:00'),
  (265, 3, 'apableo@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Ana', NULL, 'Pableo', '09899634096', 1, 0, '2026-10-17 17:30:00', '2026-08-22 14:21:00'),
  (266, 3, 'syap@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Sheryl', 'Aquino', 'Yap', '09970477275', 1, 0, '2026-05-09 04:36:00', '2026-01-20 14:36:00'),
  (267, 3, 'fgaid@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Fe', 'Reyes', 'Gaid', '09256987967', 1, 0, NULL, '2026-07-26 15:35:00'),
  (268, 3, 'msalazar@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Mildred', 'Santos', 'Salazar', '09796200575', 1, 0, '2026-07-12 00:31:00', '2026-06-19 10:31:00'),
  (269, 3, 'lcabrera2@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Lorna', NULL, 'Cabrera', '09236143733', 1, 0, NULL, '2026-01-18 08:11:00'),
  (270, 3, 'cuy@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Catherine', 'Corpuz', 'Uy', '09954935296', 0, 0, '2026-08-27 07:04:00', '2026-06-11 14:04:00'),
  (271, 3, 'kdelacruz@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Karen', NULL, 'dela Cruz', '09823437808', 1, 0, '2026-09-05 20:07:00', '2026-06-30 17:07:00'),
  (272, 3, 'rdomingo@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Ricardo', NULL, 'Domingo', '09955089298', 1, 0, '2026-03-19 18:40:00', '2026-01-13 13:40:00'),
  (273, 3, 'cvaldez2@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Christian', NULL, 'Valdez', '09285290508', 1, 0, '2026-09-08 10:17:00', '2026-08-15 15:17:00'),
  (274, 3, 'sdalumpines@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Shiela', 'Pineda', 'Dalumpines', '09900369952', 1, 0, '2026-10-04 08:25:00', '2026-08-26 17:25:00'),
  (275, 3, 'aparaiso2@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Angelica', 'Dizon', 'Paraiso', '09346857831', 1, 0, '2026-05-05 15:31:00', '2026-02-25 11:31:00'),
  (276, 3, 'anapoles@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Alfredo', 'Lopez', 'Napoles', '09147043972', 1, 0, '2026-10-17 17:30:00', '2026-09-24 11:50:00'),
  (277, 3, 'jyap2@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Jose', 'Evangelista', 'Yap', '09514693969', 1, 0, NULL, '2026-05-09 08:29:00'),
  (278, 3, 'lpableo@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Lito', 'Cabrera', 'Pableo', '09819880878', 1, 0, NULL, '2026-03-09 10:30:00'),
  (279, 3, 'clopez@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Christian', 'Santos', 'Lopez', '09335729351', 1, 0, '2026-08-20 11:02:00', '2026-06-22 08:02:00'),
  (280, 3, 'myap@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Maria', 'Garcia', 'Yap', '09955649475', 1, 0, '2026-10-07 21:34:00', '2026-09-29 14:34:00'),
  (281, 3, 'eflores@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Ernesto', 'Dizon', 'Flores', '09729388312', 1, 0, '2026-07-16 23:29:00', '2026-03-29 12:29:00'),
  (282, 3, 'mcruz@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Maria', 'Evangelista', 'Cruz', '09561923061', 1, 0, '2026-08-10 02:18:00', '2026-04-28 13:18:00'),
  (283, 3, 'mramos@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Marites', 'Evangelista', 'Ramos', '09152330676', 1, 0, '2026-10-17 16:21:00', '2026-10-09 08:21:00'),
  (284, 3, 'rlopez@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Ricardo', 'Garcia', 'Lopez', '09126467186', 1, 0, '2026-07-05 19:43:00', '2026-02-22 08:43:00'),
  (285, 3, 'wacosta@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Wilfredo', 'Bernardo', 'Acosta', '09244067160', 1, 0, '2026-06-10 17:32:00', '2026-03-22 14:32:00'),
  (286, 3, 'glopez@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Glenda', NULL, 'Lopez', '09558546800', 1, 0, NULL, '2026-04-10 13:55:00'),
  (287, 3, 'juy2@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Jovelyn', NULL, 'Uy', '09432006355', 1, 0, '2026-03-07 19:06:00', '2026-02-27 08:06:00'),
  (288, 3, 'rfernandez2@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Rowena', 'Pineda', 'Fernandez', '09135311677', 1, 0, '2026-10-17 17:30:00', '2026-09-08 16:04:00'),
  (289, 3, 'rmacasero@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Rosario', 'Cabrera', 'Macasero', '09918826443', 1, 0, '2026-03-03 10:59:00', '2026-02-26 16:59:00'),
  (290, 3, 'opadilla@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Ofelia', 'Corpuz', 'Padilla', '09935967207', 1, 0, '2026-08-11 23:56:00', '2026-04-26 17:56:00'),
  (291, 3, 'mcastillo@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Mary Grace', 'Santos', 'Castillo', '09371118894', 1, 0, '2026-03-04 16:59:00', '2026-02-20 14:59:00'),
  (292, 3, 'pacosta@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Perla', 'Evangelista', 'Acosta', '09392965761', 1, 0, '2026-08-01 23:48:00', '2026-05-23 10:48:00'),
  (293, 3, 'tgonzales@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Tomas', 'Reyes', 'Gonzales', '09636627256', 1, 0, '2026-09-27 23:51:00', '2026-07-14 16:51:00'),
  (294, 3, 'jdalumpines@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Jun', 'Estrada', 'Dalumpines', '09772786251', 1, 0, '2026-09-07 04:03:00', '2026-07-18 15:03:00'),
  (295, 3, 'dpadilla@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Dante', NULL, 'Padilla', '09846491420', 1, 0, '2026-03-28 22:39:00', '2026-03-22 13:39:00'),
  (296, 3, 'crabago@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Catherine', 'Dizon', 'Rabago', '09229009449', 1, 0, NULL, '2026-08-27 13:38:00'),
  (297, 3, 'nebarle@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Norma', 'Mercado', 'Ebarle', '09742629330', 1, 0, '2026-07-09 01:52:00', '2026-03-17 08:52:00'),
  (298, 3, 'ftan@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Fe', NULL, 'Tan', '09702286051', 1, 0, '2026-10-17 17:30:00', '2026-09-15 10:59:00'),
  (299, 3, 'pacosta2@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Pedro', NULL, 'Acosta', '09254628958', 1, 0, '2026-07-07 02:56:00', '2026-02-18 12:56:00'),
  (300, 3, 'oybanez@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Orlando', 'Gutierrez', 'Ybanez', NULL, 1, 0, NULL, '2026-07-28 09:17:00');
INSERT INTO users (user_id, role_id, email, password_hash, first_name, middle_name, last_name, phone, is_active, must_change_password, last_login_at, created_at) VALUES
  (301, 3, 'ngarcia@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Nelson', 'Santos', 'Garcia', '09197080414', 0, 0, '2026-06-01 18:37:00', '2026-02-09 12:37:00'),
  (302, 3, 'iflores@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Irene', 'Corpuz', 'Flores', NULL, 1, 0, '2026-08-24 02:02:00', '2026-06-06 14:02:00'),
  (303, 3, 'lsumalinog3@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Lorna', NULL, 'Sumalinog', '09505029751', 1, 0, '2026-05-16 17:00:00', '2026-02-09 16:00:00'),
  (304, 3, 'mcabahug2@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Marites', NULL, 'Cabahug', '09820078281', 1, 0, NULL, '2026-10-10 13:47:00'),
  (305, 3, 'mebarle2@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Mildred', 'Lopez', 'Ebarle', '09334127505', 1, 0, '2026-07-20 04:29:00', '2026-07-01 16:29:00'),
  (306, 3, 'pchavez@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Pedro', NULL, 'Chavez', '09806063747', 1, 0, '2026-09-01 05:06:00', '2026-07-18 13:06:00'),
  (307, 3, 'sdomingo2@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Sheryl', 'Pineda', 'Domingo', '09175897628', 1, 0, '2026-10-17 17:30:00', '2026-09-17 16:44:00'),
  (308, 3, 'mramos2@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Mark Anthony', 'Gutierrez', 'Ramos', NULL, 1, 0, '2026-10-15 15:53:00', '2026-07-08 10:53:00'),
  (309, 3, 'amagno@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Aileen', NULL, 'Magno', '09215040885', 1, 0, '2026-10-06 08:05:00', '2026-09-28 08:05:00'),
  (310, 3, 'fuy@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Fernando', NULL, 'Uy', '09206272199', 1, 0, '2026-10-17 17:30:00', '2026-09-21 09:16:00'),
  (311, 3, 'bmercado@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Bryan', NULL, 'Mercado', '09984934174', 1, 0, '2026-03-01 00:09:00', '2026-02-06 11:09:00'),
  (312, 3, 'plim@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Perla', 'Mercado', 'Lim', '09571493732', 1, 0, '2026-10-17 17:30:00', '2026-09-17 08:41:00'),
  (313, 3, 'lnapoles@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Lorna', 'Mercado', 'Napoles', '09241608491', 1, 0, '2026-06-01 05:55:00', '2026-02-15 16:55:00'),
  (314, 3, 'cchavez@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Carlo', NULL, 'Chavez', '09300344296', 1, 0, '2026-10-05 19:11:00', '2026-05-09 17:11:00'),
  (315, 3, 'cpableo@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Catherine', NULL, 'Pableo', '09461572648', 1, 0, '2026-10-17 17:30:00', '2026-10-12 09:58:00'),
  (316, 3, 'osia@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Oscar', NULL, 'Sia', '09796351872', 1, 0, '2026-07-28 07:36:00', '2026-05-22 17:36:00'),
  (317, 3, 'rpacana@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Rosario', 'Santos', 'Pacana', '09238430314', 1, 0, '2026-09-19 04:48:00', '2026-09-05 10:48:00'),
  (318, 3, 'emercado@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Ernesto', 'Garcia', 'Mercado', '09121114951', 1, 0, '2026-04-10 23:44:00', '2026-02-12 17:44:00'),
  (319, 3, 'ccabahug@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Corazon', 'Pineda', 'Cabahug', '09864860419', 1, 0, '2026-08-20 19:56:00', '2026-06-06 08:56:00'),
  (320, 3, 'gdelacruz@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Gregorio', 'Santos', 'dela Cruz', '09849563040', 1, 0, NULL, '2026-10-03 16:50:00'),
  (321, 3, 'ctumulak@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Corazon', 'Reyes', 'Tumulak', '09487394956', 1, 0, '2026-05-13 18:17:00', '2026-04-14 14:17:00'),
  (322, 3, 'emaranon@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Estrella', NULL, 'Maranon', '09717163785', 1, 0, '2026-07-04 09:37:00', '2026-03-10 09:37:00'),
  (323, 3, 'mvaldez@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Manuel', 'Evangelista', 'Valdez', '09176073647', 1, 0, '2026-10-17 17:30:00', '2026-06-17 13:09:00'),
  (324, 3, 'nchavez@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Nestor', 'Dizon', 'Chavez', '09346899798', 1, 0, NULL, '2026-05-01 17:57:00'),
  (325, 3, 'tcabrera@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Tomas', NULL, 'Cabrera', '09318362918', 1, 0, '2026-10-17 17:30:00', '2026-08-27 08:39:00'),
  (326, 3, 'nsantos@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Nenita', NULL, 'Santos', NULL, 1, 0, '2026-09-17 19:43:00', '2026-04-28 08:43:00'),
  (327, 3, 'mnapoles@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Mark Anthony', 'Santos', 'Napoles', '09139793269', 1, 0, '2026-04-14 00:44:00', '2026-01-30 11:44:00'),
  (328, 3, 'jnapoles@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Jaime', 'Garcia', 'Napoles', '09562094687', 1, 0, '2026-01-27 11:28:00', '2026-01-15 10:28:00'),
  (329, 3, 'igabule@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Ignacio', 'Garcia', 'Gabule', '09616292326', 1, 0, '2026-10-12 01:52:00', '2026-07-23 08:52:00'),
  (330, 3, 'anavarro2@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Angelica', 'Gutierrez', 'Navarro', '09624517998', 1, 0, '2026-10-17 17:30:00', '2026-07-23 15:27:00'),
  (331, 3, 'gtan@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Gerardo', 'Lopez', 'Tan', '09577063969', 1, 0, NULL, '2026-04-08 16:46:00'),
  (332, 3, 'fgonzales@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Fe', 'Santos', 'Gonzales', '09653619999', 1, 0, '2026-07-15 06:39:00', '2026-07-14 10:39:00'),
  (333, 3, 'aaguilar@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Arturo', 'Dizon', 'Aguilar', '09535277413', 1, 0, '2026-03-28 05:06:00', '2026-03-11 13:06:00'),
  (334, 3, 'rsia@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Reynaldo', 'Estrada', 'Sia', '09557156777', 1, 0, '2026-10-17 17:30:00', '2026-09-17 09:23:00'),
  (335, 3, 'plopez@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Perla', 'Aquino', 'Lopez', '09140109974', 1, 0, '2026-04-21 10:22:00', '2026-03-31 17:22:00'),
  (336, 3, 'hbacalso@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Herminio', 'Pineda', 'Bacalso', NULL, 1, 0, '2026-09-12 23:17:00', '2026-09-09 10:17:00'),
  (337, 3, 'jvillareal@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Jasmine', NULL, 'Villareal', '09682099124', 1, 0, '2026-06-24 12:48:00', '2026-06-23 10:48:00'),
  (338, 3, 'msia@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Manuel', NULL, 'Sia', '09872835497', 1, 0, '2026-06-06 09:49:00', '2026-04-02 13:49:00'),
  (339, 3, 'jgabule@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Jennifer', 'Estrada', 'Gabule', '09255400144', 1, 0, NULL, '2026-06-03 08:50:00'),
  (340, 3, 'sparaiso@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Shiela', NULL, 'Paraiso', '09396386616', 1, 0, '2026-03-26 02:42:00', '2026-01-20 08:42:00'),
  (341, 3, 'asalazar2@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Angelica', NULL, 'Salazar', '09968214336', 1, 0, NULL, '2026-04-03 14:04:00'),
  (342, 3, 'kacosta@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Kevin', NULL, 'Acosta', '09639509470', 1, 0, '2026-08-29 23:38:00', '2026-04-20 17:38:00'),
  (343, 3, 'jybanez2@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Jennifer', 'Aquino', 'Ybanez', '09868531088', 1, 0, '2026-09-27 17:02:00', '2026-08-15 17:02:00'),
  (344, 3, 'ebacalso2@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Emmanuel', 'Dizon', 'Bacalso', '09190354873', 1, 0, '2026-05-31 20:35:00', '2026-04-19 10:35:00'),
  (345, 3, 'ksantos@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Kevin', NULL, 'Santos', '09757211012', 1, 0, '2026-09-12 00:47:00', '2026-08-20 12:47:00'),
  (346, 3, 'jrabago@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Jose', 'Evangelista', 'Rabago', '09402052775', 1, 0, NULL, '2026-10-08 17:56:00'),
  (347, 3, 'dbacalso@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Dante', NULL, 'Bacalso', '09859402951', 1, 0, '2026-06-02 23:29:00', '2026-01-19 08:29:00'),
  (348, 3, 'lsantos@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Lorna', 'Aquino', 'Santos', '09181604961', 1, 0, '2026-06-26 12:20:00', '2026-03-30 09:20:00'),
  (349, 3, 'rfernandez3@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Rhea', NULL, 'Fernandez', NULL, 1, 0, NULL, '2026-06-28 08:55:00'),
  (350, 3, 'flim@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Fernando', 'Aquino', 'Lim', '09306699484', 1, 0, '2026-06-11 01:09:00', '2026-03-22 17:09:00');
INSERT INTO users (user_id, role_id, email, password_hash, first_name, middle_name, last_name, phone, is_active, must_change_password, last_login_at, created_at) VALUES
  (351, 3, 'gaguilar@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Gregorio', 'Dizon', 'Aguilar', '09334972124', 1, 0, '2026-05-10 07:07:00', '2026-02-28 13:07:00'),
  (352, 3, 'kquizon@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Kevin', 'Corpuz', 'Quizon', '09890606967', 1, 0, '2026-04-19 17:54:00', '2026-01-19 09:54:00'),
  (353, 3, 'raguilar@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Rowena', NULL, 'Aguilar', '09202507946', 1, 0, '2026-09-16 20:56:00', '2026-07-21 14:56:00'),
  (354, 3, 'cdumaguit@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Corazon', 'Cabrera', 'Dumaguit', '09431643922', 1, 0, '2026-09-25 20:01:00', '2026-07-17 09:01:00'),
  (355, 3, 'byap2@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Benjamin', NULL, 'Yap', '09564811077', 1, 0, '2026-08-20 04:05:00', '2026-04-29 15:05:00'),
  (356, 3, 'rdumaguit2@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Romeo', NULL, 'Dumaguit', '09184581371', 1, 0, '2026-02-22 21:34:00', '2026-02-03 08:34:00'),
  (357, 3, 'agabule@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Alvin', 'Bernardo', 'Gabule', '09597257594', 1, 0, '2026-10-17 17:30:00', '2026-07-09 16:42:00'),
  (358, 3, 'rracaza@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Reynaldo', 'Aquino', 'Racaza', '09866495790', 1, 0, '2026-04-06 20:41:00', '2026-03-15 10:41:00'),
  (359, 3, 'olagrosas@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Oscar', NULL, 'Lagrosas', '09682695531', 1, 0, '2026-07-20 00:39:00', '2026-03-17 16:39:00'),
  (360, 3, 'fflores@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Fe', 'Cabrera', 'Flores', '09789868858', 1, 0, '2026-10-17 17:30:00', '2026-09-27 12:57:00'),
  (361, 3, 'ireyes@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Ivy', 'Estrada', 'Reyes', '09520667716', 1, 0, '2026-10-06 11:50:00', '2026-08-08 09:50:00'),
  (362, 3, 'rmagno@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Ricardo', NULL, 'Magno', '09487195053', 1, 0, '2026-02-25 20:42:00', '2026-01-21 10:42:00'),
  (363, 3, 'lgaid@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Lito', 'Evangelista', 'Gaid', '09893020039', 1, 0, '2026-03-14 05:42:00', '2026-02-11 12:42:00'),
  (364, 3, 'jlagrosas@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Jaime', 'Gutierrez', 'Lagrosas', '09724006569', 1, 0, '2026-10-17 17:30:00', '2026-08-13 17:38:00'),
  (365, 3, 'jchavez@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Jerome', NULL, 'Chavez', '09533586516', 1, 0, '2026-10-17 17:30:00', '2026-08-14 16:27:00'),
  (366, 3, 'rvillareal2@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Rica', NULL, 'Villareal', '09673092916', 1, 0, '2026-07-25 08:10:00', '2026-07-14 17:10:00'),
  (367, 3, 'ksia@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Kevin', 'Pineda', 'Sia', '09412089511', 1, 0, '2026-01-31 13:43:00', '2026-01-20 12:43:00'),
  (368, 3, 'rramos@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Rodel', NULL, 'Ramos', '09832881336', 1, 0, '2026-10-10 20:53:00', '2026-05-22 16:53:00'),
  (369, 3, 'ilim@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Ignacio', 'Corpuz', 'Lim', '09140495903', 1, 0, '2026-10-17 17:30:00', '2026-07-04 08:07:00'),
  (370, 3, 'vmacasero@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Vilma', NULL, 'Macasero', '09579184303', 1, 0, '2026-10-17 17:30:00', '2026-08-31 15:11:00'),
  (371, 3, 'jmaranon@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Jovelyn', 'Lopez', 'Maranon', '09162017111', 1, 0, '2026-10-17 17:30:00', '2026-06-18 12:33:00'),
  (372, 3, 'acabahug@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Angelica', 'Estrada', 'Cabahug', '09481276460', 1, 0, NULL, '2026-04-03 10:01:00'),
  (373, 3, 'mmendoza@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Mildred', 'Santos', 'Mendoza', '09750526089', 1, 0, '2026-10-17 17:30:00', '2026-08-24 08:07:00'),
  (374, 3, 'bmaranon@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Bryan', 'Bernardo', 'Maranon', NULL, 1, 0, '2026-10-01 23:06:00', '2026-09-22 15:06:00'),
  (375, 3, 'jcabrera@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Joy', 'Dizon', 'Cabrera', '09378653595', 1, 0, '2026-09-03 14:33:00', '2026-07-29 08:33:00'),
  (376, 3, 'epepito@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Estrella', 'Bernardo', 'Pepito', '09536792773', 1, 0, '2026-10-17 17:30:00', '2026-07-05 08:35:00'),
  (377, 3, 'nacosta@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Nelson', 'Reyes', 'Acosta', '09235638582', 1, 0, '2026-10-17 17:30:00', '2026-10-11 09:13:00'),
  (378, 3, 'spadilla@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Salvador', NULL, 'Padilla', '09167896015', 1, 0, '2026-03-19 16:35:00', '2026-02-17 16:35:00'),
  (379, 3, 'atabamo@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Alvin', 'Reyes', 'Tabamo', NULL, 1, 0, '2026-06-04 00:53:00', '2026-04-28 14:53:00'),
  (380, 3, 'jgaid@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Jovelyn', 'Gutierrez', 'Gaid', '09929057621', 1, 0, '2026-08-21 11:37:00', '2026-05-25 15:37:00'),
  (381, 3, 'fpepito@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Fe', 'Corpuz', 'Pepito', NULL, 1, 0, '2026-09-17 08:03:00', '2026-05-16 08:03:00'),
  (382, 3, 'calonzo@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Cesar', NULL, 'Alonzo', '09728183741', 1, 0, '2026-10-11 07:19:00', '2026-09-30 11:19:00'),
  (383, 3, 'elagrosas@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Elena', NULL, 'Lagrosas', '09190236573', 1, 0, NULL, '2026-06-10 13:11:00'),
  (384, 3, 'jdomingo@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Jessie', NULL, 'Domingo', '09370878208', 1, 0, '2026-07-20 01:02:00', '2026-03-04 17:02:00'),
  (385, 3, 'rracaza2@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Remedios', 'Evangelista', 'Racaza', '09649972840', 1, 0, '2026-05-17 03:56:00', '2026-03-25 11:56:00'),
  (386, 3, 'bmendoza@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Benjamin', 'Aquino', 'Mendoza', '09162901455', 1, 0, '2026-06-20 01:19:00', '2026-05-17 09:19:00'),
  (387, 3, 'gcastillo@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Gemma', NULL, 'Castillo', '09931483932', 1, 0, '2026-02-18 02:00:00', '2026-02-01 09:00:00'),
  (388, 3, 'orabago2@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Oscar', NULL, 'Rabago', '09634567869', 1, 0, '2026-10-04 18:30:00', '2026-09-30 12:30:00'),
  (389, 3, 'mdumaguit@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Mark Anthony', 'Santos', 'Dumaguit', '09596047801', 1, 0, '2026-08-01 22:06:00', '2026-05-07 10:06:00'),
  (390, 3, 'glagrosas@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Gilbert', NULL, 'Lagrosas', '09892546459', 1, 0, '2026-07-02 22:29:00', '2026-04-17 10:29:00'),
  (391, 3, 'gsantos@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Glenda', NULL, 'Santos', '09816317526', 1, 0, '2026-10-17 17:30:00', '2026-07-31 11:26:00'),
  (392, 3, 'sfernandez@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Salvador', 'Evangelista', 'Fernandez', '09326398246', 1, 0, '2026-06-27 01:43:00', '2026-03-22 12:43:00'),
  (393, 3, 'cfernandez@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Cesar', NULL, 'Fernandez', '09459301084', 1, 0, '2026-05-27 20:36:00', '2026-03-22 11:36:00'),
  (394, 3, 'ireyes2@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Ignacio', NULL, 'Reyes', NULL, 1, 0, '2026-10-17 17:30:00', '2026-07-17 08:10:00'),
  (395, 3, 'afernandez@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Arturo', NULL, 'Fernandez', '09717242196', 1, 0, '2026-10-17 17:30:00', '2026-07-07 11:47:00'),
  (396, 3, 'acabahug2@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Alfredo', 'Pineda', 'Cabahug', '09894404703', 1, 0, '2026-10-17 17:30:00', '2026-10-05 11:00:00'),
  (397, 3, 'oabellanosa@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Oscar', 'Santos', 'Abellanosa', '09866319299', 1, 0, '2026-09-27 23:24:00', '2026-08-31 15:24:00'),
  (398, 3, 'olim@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Ofelia', 'Dizon', 'Lim', '09754987890', 1, 0, '2026-10-17 17:30:00', '2026-09-07 14:40:00'),
  (399, 3, 'dcruz2@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Dolores', 'Santos', 'Cruz', '09722175097', 1, 0, NULL, '2026-08-08 13:46:00'),
  (400, 3, 'cabellanosa@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Catherine', NULL, 'Abellanosa', NULL, 1, 0, '2026-07-09 04:46:00', '2026-04-21 10:46:00');
INSERT INTO users (user_id, role_id, email, password_hash, first_name, middle_name, last_name, phone, is_active, must_change_password, last_login_at, created_at) VALUES
  (401, 3, 'isoriano@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Ivy', NULL, 'Soriano', '09282928676', 1, 0, '2026-10-17 17:30:00', '2026-09-26 08:23:00'),
  (402, 3, 'smacasero@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Salvador', 'Pineda', 'Macasero', '09425907410', 1, 0, '2026-09-01 16:51:00', '2026-07-18 13:51:00'),
  (403, 3, 'jestrada@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Jennifer', NULL, 'Estrada', '09954843675', 1, 0, '2026-08-01 23:46:00', '2026-06-21 08:46:00'),
  (404, 3, 'iroque@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Ivy', 'Reyes', 'Roque', NULL, 1, 0, '2026-09-22 02:15:00', '2026-05-20 15:15:00'),
  (405, 3, 'gebarle@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Glenda', 'Dizon', 'Ebarle', '09652655466', 1, 0, '2026-10-06 00:58:00', '2026-05-23 08:58:00'),
  (406, 3, 'rsia2@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Roberto', NULL, 'Sia', '09514989669', 1, 0, '2026-08-03 08:56:00', '2026-04-09 16:56:00'),
  (407, 3, 'igabule2@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Ivy', 'Lopez', 'Gabule', NULL, 1, 0, '2026-09-10 20:53:00', '2026-07-01 16:53:00'),
  (408, 3, 'dpableo2@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Divina', NULL, 'Pableo', NULL, 1, 0, '2026-06-15 00:25:00', '2026-03-16 11:25:00'),
  (409, 3, 'jnavarro@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Jennifer', NULL, 'Navarro', '09369919642', 1, 0, '2026-08-05 15:43:00', '2026-05-09 10:43:00'),
  (410, 3, 'lnapoles2@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Lito', NULL, 'Napoles', '09698783568', 1, 0, '2026-10-17 17:30:00', '2026-08-13 11:04:00'),
  (411, 3, 'isoriano2@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Imelda', 'Cabrera', 'Soriano', '09343474700', 1, 0, '2026-06-18 00:43:00', '2026-01-29 15:43:00'),
  (412, 3, 'caguilar@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Corazon', NULL, 'Aguilar', '09515117770', 1, 0, '2026-06-24 07:35:00', '2026-03-22 15:35:00'),
  (413, 3, 'lsoriano@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Leonardo', NULL, 'Soriano', '09116957680', 1, 0, '2026-06-22 01:54:00', '2026-03-06 17:54:00'),
  (414, 3, 'kcabrera@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Kevin', 'Bernardo', 'Cabrera', '09996027354', 1, 0, '2026-10-17 17:30:00', '2026-10-07 14:07:00'),
  (415, 3, 'nreyes@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Nelson', 'Bernardo', 'Reyes', '09360316702', 1, 0, '2026-10-17 17:30:00', '2026-09-24 15:56:00'),
  (416, 3, 'plagrosas@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Pedro', 'Mercado', 'Lagrosas', '09734203363', 1, 0, '2026-08-29 10:46:00', '2026-05-27 16:46:00'),
  (417, 3, 'nyap2@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Nestor', NULL, 'Yap', '09443868728', 1, 0, '2026-07-22 15:59:00', '2026-06-03 11:59:00'),
  (418, 3, 'emagno2@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Estrella', NULL, 'Magno', '09546683918', 1, 0, '2026-10-17 17:30:00', '2026-10-05 08:06:00'),
  (419, 3, 'tfernandez@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Tomas', 'Evangelista', 'Fernandez', '09452267970', 1, 0, '2026-07-30 01:40:00', '2026-07-14 14:40:00'),
  (420, 3, 'fgarcia@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Felix', NULL, 'Garcia', '09219919815', 1, 0, '2026-03-27 02:14:00', '2026-03-07 17:14:00'),
  (421, 3, 'amendoza@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Alvin', 'Evangelista', 'Mendoza', '09921948316', 1, 0, '2026-10-17 17:30:00', '2026-09-19 12:22:00'),
  (422, 3, 'ngabule@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Nelson', NULL, 'Gabule', '09130647046', 1, 0, '2026-09-04 01:25:00', '2026-07-06 10:25:00'),
  (423, 3, 'vflores@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Vilma', 'Lopez', 'Flores', NULL, 1, 0, '2026-06-22 17:31:00', '2026-03-31 15:31:00'),
  (424, 3, 'rmercado@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Rodel', NULL, 'Mercado', '09728601371', 1, 0, '2026-10-17 17:30:00', '2026-09-25 16:30:00'),
  (425, 3, 'esantos@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Ernesto', 'Pineda', 'Santos', '09439230440', 1, 0, '2026-10-09 19:18:00', '2026-09-22 17:18:00'),
  (426, 3, 'ecabrera@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Elena', 'Bernardo', 'Cabrera', '09748523400', 1, 0, '2026-05-17 02:16:00', '2026-03-30 15:16:00'),
  (427, 3, 'dmagno@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Divina', 'Dizon', 'Magno', '09432075770', 1, 0, NULL, '2026-01-16 17:19:00'),
  (428, 3, 'gpableo@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Gregorio', 'Gutierrez', 'Pableo', '09852368291', 1, 0, '2026-07-22 02:59:00', '2026-05-31 15:59:00'),
  (429, 3, 'cmacasero@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Cesar', NULL, 'Macasero', '09651847473', 1, 0, '2026-08-14 03:57:00', '2026-04-16 10:57:00'),
  (430, 3, 'rdelacruz@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Rica', 'Mercado', 'dela Cruz', '09743445878', 1, 0, '2026-08-15 07:42:00', '2026-03-18 16:42:00'),
  (431, 3, 'ogaid@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Ofelia', 'Bernardo', 'Gaid', '09147200558', 1, 0, '2026-10-17 17:30:00', '2026-09-29 11:31:00'),
  (432, 3, 'sgonzales2@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Shiela', NULL, 'Gonzales', '09648387869', 1, 0, '2026-09-02 11:56:00', '2026-06-06 11:56:00'),
  (433, 3, 'bracaza@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Bryan', 'Dizon', 'Racaza', '09646069915', 1, 0, '2026-10-17 17:30:00', '2026-09-08 15:20:00'),
  (434, 3, 'jvaldez@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Jessie', 'Cabrera', 'Valdez', '09296567249', 1, 0, '2026-08-05 22:44:00', '2026-06-07 09:44:00'),
  (435, 3, 'cmercado2@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Carlo', 'Evangelista', 'Mercado', '09450232774', 1, 0, '2026-05-17 03:14:00', '2026-05-15 15:14:00'),
  (436, 3, 'jybanez3@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Jovelyn', 'Corpuz', 'Ybanez', '09806903224', 1, 0, '2026-06-29 05:45:00', '2026-05-15 12:45:00'),
  (437, 3, 'mflores2@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Mary Grace', NULL, 'Flores', '09488679843', 1, 0, NULL, '2026-05-19 13:23:00'),
  (438, 3, 'cmaranon@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Cristina', NULL, 'Maranon', '09151042621', 1, 0, '2026-10-17 17:30:00', '2026-08-06 17:45:00'),
  (439, 3, 'jgarcia2@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Jasmine', 'Aquino', 'Garcia', '09368502200', 1, 0, '2026-05-03 05:59:00', '2026-04-02 10:59:00'),
  (440, 3, 'bsia@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Bryan', 'Corpuz', 'Sia', '09164682303', 1, 0, '2026-10-06 01:45:00', '2026-08-01 14:45:00'),
  (441, 3, 'rvillareal3@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Rodel', NULL, 'Villareal', NULL, 1, 0, '2026-06-24 09:26:00', '2026-04-08 09:26:00'),
  (442, 3, 'nocampo@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Nestor', 'Corpuz', 'Ocampo', '09723791108', 0, 0, '2026-08-01 21:06:00', '2026-04-19 11:06:00'),
  (443, 3, 'tnapoles@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Teresita', 'Pineda', 'Napoles', '09281160253', 1, 0, '2026-08-31 15:13:00', '2026-05-19 09:13:00'),
  (444, 3, 'gmendoza@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Gemma', 'Dizon', 'Mendoza', '09456965340', 1, 0, '2026-06-27 03:25:00', '2026-04-23 14:25:00'),
  (445, 3, 'csia2@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Corazon', NULL, 'Sia', '09514907998', 1, 0, '2026-10-17 17:30:00', '2026-07-20 11:14:00'),
  (446, 3, 'oquizon2@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Oscar', NULL, 'Quizon', '09457812623', 1, 0, '2026-05-30 10:41:00', '2026-03-15 17:41:00'),
  (447, 3, 'echavez@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Emmanuel', 'Pineda', 'Chavez', '09928821438', 1, 0, '2026-07-01 18:40:00', '2026-05-27 16:40:00'),
  (448, 3, 'rramos2@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Reynaldo', 'Lopez', 'Ramos', '09834231327', 1, 0, '2026-09-08 05:06:00', '2026-05-27 15:06:00'),
  (449, 3, 'nmacasero@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Noel', 'Aquino', 'Macasero', '09226152284', 1, 0, '2026-05-13 02:04:00', '2026-01-19 09:04:00'),
  (450, 3, 'croque@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Catherine', 'Bernardo', 'Roque', '09838170585', 1, 0, '2026-05-21 22:06:00', '2026-04-02 11:06:00');
INSERT INTO users (user_id, role_id, email, password_hash, first_name, middle_name, last_name, phone, is_active, must_change_password, last_login_at, created_at) VALUES
  (451, 3, 'nflores2@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Nenita', 'Dizon', 'Flores', '09866256706', 1, 0, '2026-10-17 17:30:00', '2026-10-03 15:52:00'),
  (452, 3, 'sgarcia@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Shiela', 'Evangelista', 'Garcia', '09119155692', 1, 0, '2026-08-08 03:50:00', '2026-06-29 13:50:00'),
  (453, 3, 'gsoriano@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Gemma', NULL, 'Soriano', '09942918189', 1, 0, '2026-10-17 17:30:00', '2026-09-22 13:23:00'),
  (454, 3, 'bracaza2@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Belen', NULL, 'Racaza', '09110623950', 1, 0, '2026-10-17 17:30:00', '2026-06-29 15:34:00'),
  (455, 3, 'vlopez@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Virgilio', NULL, 'Lopez', '09238870480', 0, 0, '2026-07-21 23:21:00', '2026-03-15 17:21:00'),
  (456, 3, 'rocampo@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Rodel', NULL, 'Ocampo', '09221423097', 1, 0, '2026-10-17 17:30:00', '2026-10-11 08:22:00'),
  (457, 3, 'wparaiso@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Wilfredo', 'Lopez', 'Paraiso', NULL, 1, 0, '2026-10-17 17:30:00', '2026-07-22 14:16:00'),
  (458, 3, 'wdelacruz@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Wilfredo', NULL, 'dela Cruz', '09499208667', 1, 0, '2026-04-19 21:37:00', '2026-02-06 08:37:00'),
  (459, 3, 'cracaza@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Catherine', NULL, 'Racaza', '09850388795', 1, 0, '2026-06-27 23:02:00', '2026-03-18 15:02:00'),
  (460, 3, 'dybanez@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Dante', 'Mercado', 'Ybanez', '09671615320', 1, 0, '2026-05-18 17:19:00', '2026-02-13 08:19:00'),
  (461, 3, 'llagrosas2@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Lourdes', NULL, 'Lagrosas', '09411604564', 1, 0, '2026-05-31 19:20:00', '2026-05-26 13:20:00'),
  (462, 3, 'ltumulak@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Lourdes', NULL, 'Tumulak', '09694419839', 1, 0, '2026-10-06 17:55:00', '2026-10-03 11:55:00'),
  (463, 3, 'jocampo@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Jerome', 'Corpuz', 'Ocampo', NULL, 1, 0, '2026-06-29 18:58:00', '2026-06-04 16:58:00'),
  (464, 3, 'jmendoza@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Jessie', 'Cabrera', 'Mendoza', '09765533965', 1, 0, '2026-10-17 17:30:00', '2026-08-15 11:14:00'),
  (465, 3, 'jnapoles2@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Jovelyn', NULL, 'Napoles', '09358021102', 1, 0, '2026-09-15 19:13:00', '2026-04-30 12:13:00'),
  (466, 3, 'tbacalso@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Tessie', NULL, 'Bacalso', '09167303669', 1, 0, '2026-10-17 17:30:00', '2026-09-19 16:06:00'),
  (467, 3, 'vchavez@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Victor', 'Pineda', 'Chavez', '09809863051', 1, 0, '2026-02-09 18:53:00', '2026-02-06 12:53:00'),
  (468, 3, 'esia@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Elena', NULL, 'Sia', '09295185844', 1, 0, '2026-09-18 01:05:00', '2026-07-10 11:05:00'),
  (469, 3, 'ralonzo@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Rica', NULL, 'Alonzo', '09494587878', 1, 0, '2026-07-12 22:05:00', '2026-02-19 10:05:00'),
  (470, 3, 'nparaiso@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Nelson', 'Reyes', 'Paraiso', '09583280561', 1, 0, '2026-09-17 22:11:00', '2026-05-09 15:11:00'),
  (471, 3, 'iocampo@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Ivy', 'Bernardo', 'Ocampo', '09994745446', 1, 0, '2026-10-17 17:30:00', '2026-08-12 13:16:00'),
  (472, 3, 'vaguilar@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Victor', NULL, 'Aguilar', '09733270451', 1, 0, '2026-07-09 17:43:00', '2026-02-21 14:43:00'),
  (473, 3, 'fdelacruz@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Fe', 'Aquino', 'dela Cruz', '09969144591', 1, 0, NULL, '2026-08-30 13:02:00'),
  (474, 3, 'nlopez@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Nelson', 'Aquino', 'Lopez', '09394726529', 1, 0, '2026-07-23 09:24:00', '2026-06-12 09:24:00'),
  (475, 3, 'oramos@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Orlando', 'Mercado', 'Ramos', '09150194036', 1, 0, '2026-05-11 21:12:00', '2026-02-08 08:12:00'),
  (476, 3, 'mlim2@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Michelle', NULL, 'Lim', '09378381181', 1, 0, NULL, '2026-10-05 15:59:00'),
  (477, 3, 'rbautista@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Rodrigo', NULL, 'Bautista', '09979978265', 1, 0, '2026-06-02 16:08:00', '2026-01-30 13:08:00'),
  (478, 3, 'bsoriano@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Bernard', 'Mercado', 'Soriano', '09679326723', 1, 0, '2026-06-03 09:01:00', '2026-02-23 14:01:00'),
  (479, 3, 'hsoriano@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Herminio', NULL, 'Soriano', '09326039663', 1, 0, '2026-09-02 00:48:00', '2026-08-14 11:48:00'),
  (480, 3, 'edalumpines@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Elena', NULL, 'Dalumpines', NULL, 1, 0, '2026-06-18 00:40:00', '2026-05-21 17:40:00'),
  (481, 3, 'dnavarro2@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Dante', 'Bernardo', 'Navarro', '09760457412', 1, 0, NULL, '2026-01-17 11:18:00'),
  (482, 3, 'ttorres@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Tessie', NULL, 'Torres', '09316383134', 1, 0, NULL, '2026-09-13 10:03:00'),
  (483, 3, 'wnapoles@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Wilma', 'Dizon', 'Napoles', '09749195172', 1, 0, '2026-07-04 19:36:00', '2026-05-02 08:36:00'),
  (484, 3, 'ltumulak2@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Lea', 'Garcia', 'Tumulak', '09418117037', 1, 0, '2026-05-02 06:11:00', '2026-04-16 15:11:00'),
  (485, 3, 'rcabrera@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Rodel', NULL, 'Cabrera', '09505893564', 1, 0, '2026-09-29 17:36:00', '2026-07-27 08:36:00'),
  (486, 3, 'gpacana@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Gilbert', NULL, 'Pacana', '09536142511', 1, 0, '2026-06-28 04:54:00', '2026-06-23 09:54:00'),
  (487, 3, 'cpepito@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Corazon', 'Corpuz', 'Pepito', '09588264184', 1, 0, '2026-09-08 13:40:00', '2026-08-21 08:40:00'),
  (488, 3, 'jmagno@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Jaime', 'Corpuz', 'Magno', '09964468878', 1, 0, '2026-07-17 13:23:00', '2026-04-06 08:23:00'),
  (489, 3, 'fpadilla@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Fernando', 'Reyes', 'Padilla', NULL, 1, 0, '2026-10-17 17:30:00', '2026-10-04 13:38:00'),
  (490, 3, 'ipableo@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Ivy', NULL, 'Pableo', '09522754057', 1, 0, NULL, '2026-04-27 10:50:00'),
  (491, 3, 'ipacana@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Irene', NULL, 'Pacana', '09613096371', 1, 0, '2026-03-31 15:17:00', '2026-03-03 12:17:00'),
  (492, 3, 'rreyes@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Rogelio', NULL, 'Reyes', '09782232984', 1, 0, NULL, '2026-04-26 17:49:00'),
  (493, 3, 'rmagno2@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Roberto', NULL, 'Magno', NULL, 1, 0, '2026-05-19 20:11:00', '2026-04-11 08:11:00'),
  (494, 3, 'ndelacruz@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Nelson', 'Gutierrez', 'dela Cruz', '09677378339', 1, 0, '2026-10-17 17:30:00', '2026-10-06 17:28:00'),
  (495, 3, 'snapoles@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Sheryl', 'Estrada', 'Napoles', '09934544835', 1, 0, '2026-08-08 08:12:00', '2026-06-30 08:12:00'),
  (496, 3, 'rpadilla2@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Rogelio', NULL, 'Padilla', '09766634775', 1, 0, '2026-02-13 14:40:00', '2026-01-23 10:40:00'),
  (497, 3, 'imacasero@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Ivy', 'Evangelista', 'Macasero', '09907611477', 1, 0, NULL, '2026-08-20 16:08:00'),
  (498, 3, 'bdelacruz@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Benjamin', NULL, 'dela Cruz', '09314500835', 1, 0, '2026-09-18 23:43:00', '2026-09-06 11:43:00'),
  (499, 3, 'dyap@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Divina', 'Gutierrez', 'Yap', '09122164763', 1, 0, '2026-08-23 15:08:00', '2026-08-02 11:08:00'),
  (500, 3, 'jtorres@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Jennifer', NULL, 'Torres', '09878963847', 1, 0, '2026-10-17 17:30:00', '2026-10-09 11:41:00');
INSERT INTO users (user_id, role_id, email, password_hash, first_name, middle_name, last_name, phone, is_active, must_change_password, last_login_at, created_at) VALUES
  (501, 3, 'acabahug3@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Analyn', 'Garcia', 'Cabahug', '09388497416', 1, 0, NULL, '2026-06-02 12:09:00'),
  (502, 3, 'jrivera2@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Jerome', NULL, 'Rivera', NULL, 1, 0, NULL, '2026-05-16 16:37:00'),
  (503, 3, 'tsalazar@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Tessie', 'Lopez', 'Salazar', NULL, 1, 0, '2026-08-04 12:12:00', '2026-04-24 09:12:00'),
  (504, 3, 'iyap@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Irene', NULL, 'Yap', '09153099967', 1, 0, '2026-05-30 18:32:00', '2026-04-20 13:32:00'),
  (505, 3, 'ryap@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Rogelio', 'Reyes', 'Yap', '09512119871', 1, 0, '2026-04-29 21:38:00', '2026-01-28 11:38:00'),
  (506, 3, 'jpadilla2@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Jennifer', NULL, 'Padilla', '09776141500', 1, 0, '2026-08-02 04:17:00', '2026-07-24 13:17:00'),
  (507, 3, 'vbautista@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Victor', NULL, 'Bautista', '09347424959', 1, 0, '2026-10-17 17:30:00', '2026-09-12 11:27:00'),
  (508, 3, 'rtabamo2@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Rogelio', NULL, 'Tabamo', NULL, 1, 0, '2026-08-12 15:54:00', '2026-08-09 14:54:00'),
  (509, 3, 'rcabrera2@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Rosario', NULL, 'Cabrera', '09199410940', 1, 0, '2026-08-26 04:37:00', '2026-05-05 15:37:00'),
  (510, 3, 'vdumaguit2@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Victor', 'Aquino', 'Dumaguit', '09990748748', 1, 0, '2026-08-28 22:06:00', '2026-04-27 08:06:00'),
  (511, 3, 'mrivera@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Mark Anthony', 'Estrada', 'Rivera', '09613597901', 1, 0, '2026-09-26 15:05:00', '2026-09-13 09:05:00'),
  (512, 3, 'bgonzales@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Bernard', 'Pineda', 'Gonzales', '09553199054', 1, 0, '2026-10-17 17:30:00', '2026-10-01 12:58:00'),
  (513, 3, 'arabago@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Angelica', 'Aquino', 'Rabago', '09993185255', 1, 0, '2026-10-17 17:30:00', '2026-08-03 11:53:00'),
  (514, 3, 'wtorres@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Wilfredo', 'Lopez', 'Torres', '09419816976', 1, 0, '2026-05-07 03:54:00', '2026-03-23 09:54:00'),
  (515, 3, 'mgabule2@example.com', '$2b$12$viv8MZyUw.r0mf/iGlaOzec0LnZAXEXQuu03KQcjn8xJM/e19sHwW', 'Manuel', NULL, 'Gabule', NULL, 1, 0, '2026-10-15 17:53:00', '2026-08-12 13:53:00'),
  (516, 3, 'fmacasero2@example.com', '$2b$12$IieHn0A3McAmkysYcEF67OCcV2xlRYAnCcCPeohdMPXKf0mnz3aoG', 'Fernando', 'Santos', 'Macasero', '09878867586', 1, 0, '2026-05-19 16:28:00', '2026-04-06 13:28:00'),
  (517, 3, 'rsalazar2@example.com', '$2b$12$Tk1gioOSHAh5sZUUigj81Ot8wFud2/y.6MywFazNJq0bHjVy6VWKK', 'Rosario', 'Cabrera', 'Salazar', NULL, 1, 0, '2026-05-30 00:42:00', '2026-03-21 14:42:00'),
  (518, 3, 'glagrosas2@example.com', '$2b$12$op57GX.rijCtJna1NkydCuqJ4cytaK2mdapWh4uLFnkUPZOm2srDW', 'Gemma', 'Santos', 'Lagrosas', '09189558454', 1, 0, NULL, '2026-01-22 12:32:00'),
  (519, 3, 'tvillareal@example.com', '$2b$12$7BmVCWt/ot2oEUQa5zy2POTqLUul2V0CZJykN00DEXWpzykCXQfQ.', 'Tomas', 'Garcia', 'Villareal', '09475712450', 1, 0, '2026-09-09 14:18:00', '2026-06-19 14:18:00'),
  (520, 3, 'vreyes@example.com', '$2b$12$WIjBohUP3p3ExpIskrEjBurYb7pPNo.G8LBxGX7UffJHqFv2md3/K', 'Victor', 'Bernardo', 'Reyes', '09950868993', 1, 0, '2026-03-19 08:27:00', '2026-02-07 15:27:00');

-- employee_profiles (3 rows)
INSERT INTO employee_profiles (user_id, employee_number, position_id, department_id, employment_status) VALUES
  (1, 'NHA-PNT-0001', NULL, 4, 'active'),
  (2, 'NHA-PNT-0002', 2, 4, 'active'),
  (3, 'NHA-PNT-0003', 9, 3, 'active');

COMMIT;
