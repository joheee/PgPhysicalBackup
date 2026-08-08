CREATE DATABASE aloga;

\c aloga

CREATE TABLE lambda (
    lambda_id INTEGER PRIMARY KEY,
    name      TEXT NOT NULL
);

INSERT INTO lambda (lambda_id, name) VALUES
    (1, 'wawei'),
    (2, 'jojo');
