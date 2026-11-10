-- =============================================================================
-- Plataforma educativa — esquema relacional de referencia (Amazon RDS for PostgreSQL)
-- Compatible con PostgreSQL 14+ (probado en 16).
--
-- Los archivos de los alumnos NO se guardan en la base: viven en el bucket S3
-- `edustartup-user-uploads-prod-use1-123456789012`. La tabla `submissions`
-- guarda solo metadatos y la key del objeto (`s3_key`).
-- =============================================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS citext;  -- email sin distinción de mayúsculas

-- -----------------------------------------------------------------------------
-- Tipos enumerados
-- -----------------------------------------------------------------------------
CREATE TYPE user_role         AS ENUM ('student', 'teacher', 'admin');
CREATE TYPE enrollment_status AS ENUM ('active', 'completed', 'dropped');
CREATE TYPE submission_status AS ENUM ('submitted', 'graded', 'returned');

-- -----------------------------------------------------------------------------
-- Trigger genérico para mantener updated_at
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- -----------------------------------------------------------------------------
-- users: alumnos y docentes
-- -----------------------------------------------------------------------------
CREATE TABLE users (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email       CITEXT      NOT NULL,
    full_name   TEXT        NOT NULL,
    role        user_role   NOT NULL DEFAULT 'student',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT users_email_key   UNIQUE (email),
    CONSTRAINT users_email_chk   CHECK (position('@' IN email) > 1)
);

-- -----------------------------------------------------------------------------
-- courses: cada curso tiene un docente a cargo
-- -----------------------------------------------------------------------------
CREATE TABLE courses (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title       TEXT        NOT NULL,
    description TEXT,
    teacher_id  BIGINT      NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT courses_title_teacher_key UNIQUE (title, teacher_id)
);
CREATE INDEX courses_teacher_idx ON courses (teacher_id);

-- -----------------------------------------------------------------------------
-- modules: jerarquía curso 1:N módulos, ordenados por position
-- -----------------------------------------------------------------------------
CREATE TABLE modules (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    course_id   BIGINT      NOT NULL REFERENCES courses (id) ON DELETE CASCADE,
    title       TEXT        NOT NULL,
    position    INTEGER     NOT NULL CHECK (position > 0),
    due_date    TIMESTAMPTZ,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT modules_course_position_key UNIQUE (course_id, position)
);

-- -----------------------------------------------------------------------------
-- enrollments: relación N:M alumnos <-> cursos (sin duplicados)
-- -----------------------------------------------------------------------------
CREATE TABLE enrollments (
    user_id      BIGINT            NOT NULL REFERENCES users (id)   ON DELETE CASCADE,
    course_id    BIGINT            NOT NULL REFERENCES courses (id) ON DELETE CASCADE,
    status       enrollment_status NOT NULL DEFAULT 'active',
    enrolled_at  TIMESTAMPTZ       NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ       NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, course_id)
);
-- "alumnos de un curso" (la PK ya cubre "cursos de un alumno")
CREATE INDEX enrollments_course_idx ON enrollments (course_id);

-- -----------------------------------------------------------------------------
-- submissions: entregas de los alumnos por módulo (archivo en S3)
-- -----------------------------------------------------------------------------
CREATE TABLE submissions (
    id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id       BIGINT            NOT NULL REFERENCES users (id)   ON DELETE CASCADE,
    module_id     BIGINT            NOT NULL REFERENCES modules (id) ON DELETE CASCADE,
    s3_key        TEXT              NOT NULL,            -- key del objeto en S3
    file_name     TEXT              NOT NULL,
    size_bytes    BIGINT            CHECK (size_bytes >= 0),
    status        submission_status NOT NULL DEFAULT 'submitted',
    submitted_at  TIMESTAMPTZ       NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ       NOT NULL DEFAULT now(),
    CONSTRAINT submissions_s3_key_key UNIQUE (s3_key)
);
CREATE INDEX submissions_module_idx ON submissions (module_id);
CREATE INDEX submissions_user_idx   ON submissions (user_id, submitted_at DESC);

-- -----------------------------------------------------------------------------
-- grades: una calificación por entrega (1:1)
-- -----------------------------------------------------------------------------
CREATE TABLE grades (
    submission_id BIGINT       PRIMARY KEY REFERENCES submissions (id) ON DELETE CASCADE,
    teacher_id    BIGINT       NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
    score         NUMERIC(4,2) NOT NULL CHECK (score BETWEEN 0 AND 10),
    feedback      TEXT,
    graded_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX grades_teacher_idx ON grades (teacher_id);

-- -----------------------------------------------------------------------------
-- Triggers de updated_at
-- -----------------------------------------------------------------------------
CREATE TRIGGER users_set_updated_at       BEFORE UPDATE ON users       FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER courses_set_updated_at     BEFORE UPDATE ON courses     FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER modules_set_updated_at     BEFORE UPDATE ON modules     FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER enrollments_set_updated_at BEFORE UPDATE ON enrollments FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER submissions_set_updated_at BEFORE UPDATE ON submissions FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER grades_set_updated_at      BEFORE UPDATE ON grades      FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMIT;

-- =============================================================================
-- Rol de aplicación con mínimo privilegio (la app NO usa el usuario master)
-- Ejecutar con el usuario master; la contraseña se gestiona en Secrets Manager.
-- =============================================================================
-- CREATE ROLE app_user LOGIN PASSWORD '<gestionada por Secrets Manager>';
-- GRANT USAGE ON SCHEMA public TO app_user;
-- GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_user;
-- GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO app_user;

-- =============================================================================
-- Consultas de ejemplo
-- =============================================================================

-- 1) Operación atómica: registrar la nota y cambiar el estado de la entrega
--    (:submission_id, :teacher_id y :score son parámetros de la aplicación)
-- BEGIN;
--   INSERT INTO grades (submission_id, teacher_id, score)
--   VALUES (:submission_id, :teacher_id, :score);
--   UPDATE submissions SET status = 'graded' WHERE id = :submission_id;
-- COMMIT;

-- 2) Promedio de notas y cantidad de entregas calificadas por curso
SELECT c.id, c.title,
       COUNT(g.submission_id)      AS graded_submissions,
       ROUND(AVG(g.score), 2)      AS avg_score
FROM courses c
JOIN modules     m ON m.course_id     = c.id
JOIN submissions s ON s.module_id     = m.id
JOIN grades      g ON g.submission_id = s.id
GROUP BY c.id, c.title
ORDER BY avg_score DESC;

-- 3) Alumnos con entregas pendientes (inscripto, módulo sin entrega)
SELECT u.id, u.full_name, c.title AS course, COUNT(*) AS pending_modules
FROM enrollments e
JOIN users   u ON u.id = e.user_id
JOIN courses c ON c.id = e.course_id
JOIN modules m ON m.course_id = c.id
LEFT JOIN submissions s ON s.module_id = m.id AND s.user_id = u.id
WHERE e.status = 'active' AND s.id IS NULL
GROUP BY u.id, u.full_name, c.title
ORDER BY pending_modules DESC;
