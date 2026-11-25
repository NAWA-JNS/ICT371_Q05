-- ICT371 Advanced Database | Question 5: Hostel Room Allocation
-- Name: Nawa Sumbwanyambe | Student number: 202308788
-- DBMS: PostgreSQL (PL/pgSQL; scheduling with the pg_cron extension)

DROP TABLE IF EXISTS occupancy_snapshot, allocations, rooms, students CASCADE;

-- ==== (a) Database: create the tables
CREATE TABLE students (
    student_id     SERIAL       PRIMARY KEY,
    student_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE rooms (
    room_id     SERIAL      PRIMARY KEY,
    room_number VARCHAR(10) NOT NULL UNIQUE,
    capacity    INTEGER     NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id SERIAL      PRIMARY KEY,
    student_id    INTEGER     NOT NULL REFERENCES students(student_id),
    room_id       INTEGER     NOT NULL REFERENCES rooms(room_id),
    allocated_on  DATE        NOT NULL,
    released_on   DATE        NULL,
    status        VARCHAR(10) NOT NULL DEFAULT 'ACTIVE',
    CONSTRAINT ck_alloc_status CHECK (status IN ('ACTIVE', 'ENDED')),
    CONSTRAINT ck_alloc_release CHECK (
        (status = 'ACTIVE' AND released_on IS NULL) OR
        (status = 'ENDED'  AND released_on IS NOT NULL AND released_on >= allocated_on)
    )
);

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE    NOT NULL,
    room_id       INTEGER NOT NULL REFERENCES rooms(room_id),
    occupied_beds INTEGER NOT NULL,
    free_beds     INTEGER NOT NULL,
    PRIMARY KEY (snapshot_date, room_id)
);

-- ==== (b) Function fn_free_beds
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INTEGER;
    v_active   INTEGER;
BEGIN
    SELECT capacity INTO v_capacity FROM rooms WHERE room_id = p_room_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    SELECT COUNT(*) INTO v_active
    FROM allocations
    WHERE room_id = p_room_id
      AND status = 'ACTIVE';                  -- ENDED rows are history and do not occupy beds

    RETURN v_capacity - v_active;
END;
$$;

-- ==== (d) Trigger first: enforces the rules for direct SQL as well
CREATE OR REPLACE FUNCTION trg_fn_allocations_rules()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INTEGER;
    v_others   INTEGER;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        -- Lock student then room (same order everywhere) so concurrent sessions queue up.
        PERFORM 1 FROM students WHERE student_id = NEW.student_id FOR UPDATE;
        SELECT capacity INTO v_capacity FROM rooms WHERE room_id = NEW.room_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Unknown room_id: %', NEW.room_id;
        END IF;

        -- One ACTIVE allocation per student (ignore the row being updated).
        IF EXISTS (
            SELECT 1 FROM allocations a
            WHERE a.student_id = NEW.student_id
              AND a.status = 'ACTIVE'
              AND (TG_OP = 'INSERT' OR a.allocation_id <> NEW.allocation_id)
        ) THEN
            RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
        END IF;

        -- Capacity: count the OTHER active allocations in the room.
        SELECT COUNT(*) INTO v_others
        FROM allocations a
        WHERE a.room_id = NEW.room_id
          AND a.status = 'ACTIVE'
          AND (TG_OP = 'INSERT' OR a.allocation_id <> NEW.allocation_id);

        IF v_others >= v_capacity THEN
            RAISE EXCEPTION 'Room % is full (capacity %)', NEW.room_id, v_capacity;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_allocations_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION trg_fn_allocations_rules();

-- ==== (c) Procedure pr_allocate_room
CREATE OR REPLACE PROCEDURE pr_allocate_room(p_student_id INTEGER, p_room_id INTEGER, p_allocated_on DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'Allocation date is required';
    END IF;

    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    IF EXISTS (SELECT 1 FROM allocations WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
    END IF;

    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room % has no free beds', p_room_id;
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$;

-- ==== (e) View v_room_occupancy (LEFT JOIN keeps rooms with no allocations)
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id,
       r.room_number,
       r.capacity,
       COUNT(a.allocation_id)              AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) AS free_beds
FROM rooms r
LEFT JOIN allocations a
       ON a.room_id = r.room_id
      AND a.status = 'ACTIVE'              -- condition in ON, not WHERE, so empty rooms survive
GROUP BY r.room_id, r.room_number, r.capacity;

-- ==== (f) Index: ACTIVE allocations by room
-- Partial index: ENDED history is never indexed, so it stays small and fast as history grows.
CREATE INDEX idx_allocations_active_room ON allocations (room_id) WHERE status = 'ACTIVE';

-- ==== (g) Scheduled job: pr_refresh_occupancy
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE,
           r.room_id,
           COUNT(a.allocation_id),
           r.capacity - COUNT(a.allocation_id)
    FROM rooms r
    LEFT JOIN allocations a
           ON a.room_id = r.room_id
          AND a.status = 'ACTIVE'
    GROUP BY r.room_id, r.capacity
    ON CONFLICT (snapshot_date, room_id) DO UPDATE      -- one row per date and room
    SET occupied_beds = EXCLUDED.occupied_beds,
        free_beds     = EXCLUDED.free_beds;
END;
$$;

-- Requires: CREATE EXTENSION pg_cron;
SELECT cron.schedule(
    'refresh_occupancy_daily',
    '55 23 * * *',                         -- every day at 23:55
    $$CALL pr_refresh_occupancy()$$
);

-- ==== (a) Seed data: full (R101), partly occupied (R102), empty (R103)
INSERT INTO rooms (room_number, capacity) VALUES ('R101', 2), ('R102', 3), ('R103', 2);
INSERT INTO students (student_number, full_name) VALUES
    ('202400001', 'Bwalya Kasonde'),
    ('202400002', 'Mwila Simfukwe'),
    ('202400003', 'Thandiwe Phiri'),
    ('202400004', 'Joseph Banda'),
    ('202400005', 'Agnes Lubinda');

CALL pr_allocate_room(1, 1, '2026-09-01');    -- R101 now full
CALL pr_allocate_room(2, 1, '2026-09-01');
CALL pr_allocate_room(3, 2, '2026-09-02');    -- R102 has 1 of 3
CALL pr_allocate_room(4, 3, '2026-09-03');    -- Joseph lives in R103 for a while ...
UPDATE allocations SET status = 'ENDED', released_on = '2026-10-15'
WHERE student_id = 4 AND status = 'ACTIVE';   -- ... then leaves: R103 is empty again, history kept

SELECT * FROM rooms ORDER BY room_id;
SELECT * FROM allocations ORDER BY allocation_id;

-- ==== (b) Function tests
SELECT room_id, fn_free_beds(room_id) AS free_beds FROM rooms ORDER BY room_id;   -- 0, 2, 2
DO $$ BEGIN PERFORM fn_free_beds(99); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;

-- ==== (c) Procedure tests
DO $$ BEGIN CALL pr_allocate_room(99, 2, '2026-11-25'); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_allocate_room(5, 99, '2026-11-25'); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_allocate_room(3, 3,  '2026-11-25'); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;  -- Thandiwe already ACTIVE
DO $$ BEGIN CALL pr_allocate_room(5, 1,  '2026-11-25'); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;  -- R101 full
CALL pr_allocate_room(5, 2, '2026-11-25');     -- Agnes -> R102 (2 of 3)
CALL pr_allocate_room(4, 3, '2026-11-25');     -- Joseph (ENDED history only) may be allocated again
SELECT allocation_id, student_id, room_id, status, released_on FROM allocations ORDER BY allocation_id;

-- ==== (d) Trigger tests (direct SQL, bypassing the procedure)
DO $$ BEGIN INSERT INTO allocations (student_id, room_id, allocated_on, status) VALUES (3, 3, '2026-11-25', 'ACTIVE');
       EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;   -- second ACTIVE for student 3
INSERT INTO students (student_number, full_name) VALUES ('202400006', 'Extra Student');
DO $$ BEGIN INSERT INTO allocations (student_id, room_id, allocated_on, status) VALUES (6, 1, '2026-11-25', 'ACTIVE');
       EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;   -- R101 over capacity
-- Re-activating Joseph's ENDED row (alloc 4) would give him two ACTIVE allocations
DO $$ BEGIN UPDATE allocations SET status = 'ACTIVE', released_on = NULL WHERE allocation_id = 4;
       EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;
-- Harmless UPDATE on an ACTIVE row: it is excluded from its own count, so it is not "full" against itself
UPDATE allocations SET allocated_on = '2026-09-01' WHERE allocation_id = 1;
SELECT allocation_id, allocated_on FROM allocations WHERE allocation_id = 1;

-- ==== (e) View
SELECT * FROM v_room_occupancy ORDER BY room_id;

-- ==== (f) EXPLAIN
ANALYZE allocations;
SET enable_seqscan = off;   -- tiny demo table: force the planner to show the index plan
EXPLAIN
SELECT allocation_id, student_id
FROM allocations
WHERE room_id = 2
  AND status = 'ACTIVE';
RESET enable_seqscan;

-- ==== (g) Run the job twice: still one row per date and room
CALL pr_refresh_occupancy();
SELECT * FROM occupancy_snapshot ORDER BY snapshot_date, room_id;
CALL pr_allocate_room(6, 3, CURRENT_DATE);           -- occupancy changes during the day
CALL pr_refresh_occupancy();                         -- rerun replaces the values
SELECT * FROM occupancy_snapshot ORDER BY snapshot_date, room_id;
SELECT jobname, schedule, command FROM cron.job WHERE jobname = 'refresh_occupancy_daily';
