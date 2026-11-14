-- =====================================================================
-- 01_dw_ddl.sql  |  Star schema (dw) em cima da Pagila
-- Rodar no mesmo banco "pagila" (origem = schema public, destino = dw)
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS dw;

DROP TABLE IF EXISTS dw.fato_aluguel CASCADE;
DROP TABLE IF EXISTS dw.dim_cliente  CASCADE;
DROP TABLE IF EXISTS dw.dim_filme    CASCADE;
DROP TABLE IF EXISTS dw.dim_loja     CASCADE;
DROP TABLE IF EXISTS dw.dim_data     CASCADE;

-- ---------------------------------------------------------------------
-- DIM_DATA (carregada direto por SQL, não precisa de transformação PDI)
-- ---------------------------------------------------------------------
CREATE TABLE dw.dim_data (
    data_key         integer     PRIMARY KEY,   -- yyyymmdd
    data             date        NOT NULL UNIQUE,
    ano              smallint    NOT NULL,
    trimestre        smallint    NOT NULL,
    mes              smallint    NOT NULL,
    nome_mes         varchar(15) NOT NULL,
    dia              smallint    NOT NULL,
    dia_semana       smallint    NOT NULL,      -- 1 = segunda ... 7 = domingo
    nome_dia_semana  varchar(15) NOT NULL,
    fim_de_semana    boolean     NOT NULL
);

INSERT INTO dw.dim_data
SELECT
    to_char(d, 'YYYYMMDD')::int,
    d::date,
    extract(year    FROM d)::smallint,
    extract(quarter FROM d)::smallint,
    extract(month   FROM d)::smallint,
    (ARRAY['Janeiro','Fevereiro','Março','Abril','Maio','Junho','Julho',
           'Agosto','Setembro','Outubro','Novembro','Dezembro'])[extract(month FROM d)::int],
    extract(day     FROM d)::smallint,
    extract(isodow  FROM d)::smallint,
    (ARRAY['Segunda','Terça','Quarta','Quinta','Sexta','Sábado','Domingo'])[extract(isodow FROM d)::int],
    extract(isodow  FROM d) IN (6, 7)
FROM generate_series(
        (SELECT min(rental_date)::date FROM public.rental),
        (SELECT greatest(max(return_date), max(rental_date))::date FROM public.rental),
        interval '1 day'
     ) AS d;

-- ---------------------------------------------------------------------
-- Dimensões carregadas pelo PDI (step "Dimension lookup/update")
-- As colunas versao / data_inicio / data_fim são exigidas pelo step.
-- Chaves naturais ficam SEM "NOT NULL" de propósito: na primeira execução o PDI
-- insere sozinho uma linha "desconhecido" (chave técnica 0) sem chave natural.
-- A versão vigente tem data_fim = 2199-12-31 (padrão do PDI), não NULL.
-- ---------------------------------------------------------------------
CREATE TABLE dw.dim_cliente (
    cliente_sk      integer      PRIMARY KEY,   -- chave técnica gerada pelo PDI
    versao          integer,
    data_inicio     timestamp,
    data_fim        timestamp,
    cliente_id      integer,                    -- chave natural (customer_id)
    nome            varchar(45),
    sobrenome       varchar(45),
    nome_completo   varchar(91),
    email           varchar(50),
    endereco        varchar(50),
    bairro          varchar(20),
    cidade          varchar(50),
    pais            varchar(50),
    cep             varchar(10),
    ativo           boolean,
    data_cadastro   date,
    loja_id         integer
);
CREATE INDEX ix_dim_cliente_nk ON dw.dim_cliente (cliente_id, data_inicio, data_fim);

CREATE TABLE dw.dim_filme (
    filme_sk              integer      PRIMARY KEY,
    versao                integer,
    data_inicio           timestamp,
    data_fim              timestamp,
    filme_id              integer,                 -- film_id
    titulo                varchar(255),
    descricao             text,
    ano_lancamento        integer,
    idioma                varchar(20),
    categoria             varchar(100),
    classificacao         varchar(10),
    duracao_locacao_dias  smallint,
    valor_locacao         numeric(4,2),
    duracao_min           smallint,
    custo_reposicao       numeric(5,2)
);
CREATE INDEX ix_dim_filme_nk ON dw.dim_filme (filme_id, data_inicio, data_fim);

CREATE TABLE dw.dim_loja (
    loja_sk      integer      PRIMARY KEY,
    versao       integer,
    data_inicio  timestamp,
    data_fim     timestamp,
    loja_id      integer,                          -- store_id
    endereco     varchar(50),
    bairro       varchar(20),
    cidade       varchar(50),
    pais         varchar(50),
    gerente      varchar(91)
);
CREATE INDEX ix_dim_loja_nk ON dw.dim_loja (loja_id, data_inicio, data_fim);

-- ---------------------------------------------------------------------
-- FATO_ALUGUEL  |  grão: 1 linha por aluguel (rental)
-- ---------------------------------------------------------------------
CREATE TABLE dw.fato_aluguel (
    aluguel_id          integer       PRIMARY KEY,  -- dimensão degenerada (rental_id)
    data_aluguel_key    integer       NOT NULL REFERENCES dw.dim_data (data_key),
    data_devolucao_key  integer                REFERENCES dw.dim_data (data_key),
    cliente_sk          integer       NOT NULL REFERENCES dw.dim_cliente (cliente_sk),
    filme_sk            integer       NOT NULL REFERENCES dw.dim_filme (filme_sk),
    loja_sk             integer       NOT NULL REFERENCES dw.dim_loja (loja_sk),
    dias_alugado        integer,                    -- NULL enquanto não devolvido
    qtd_pagamentos      smallint      NOT NULL DEFAULT 0,
    valor_pago          numeric(7,2)  NOT NULL DEFAULT 0,
    data_carga          timestamp     NOT NULL DEFAULT now()
);
CREATE INDEX ix_fato_aluguel_cliente ON dw.fato_aluguel (cliente_sk);
CREATE INDEX ix_fato_aluguel_filme   ON dw.fato_aluguel (filme_sk);
CREATE INDEX ix_fato_aluguel_data    ON dw.fato_aluguel (data_aluguel_key);
