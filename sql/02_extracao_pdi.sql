-- =====================================================================
-- 02_extracao_pdi.sql  |  Queries para os steps "Table input" do Pentaho
-- Ordem de carga no Job: dim_cliente -> dim_filme -> dim_loja -> fato_aluguel
-- (dim_data já foi carregada pelo 01_dw_ddl.sql)
-- =====================================================================


-- ---------------------------------------------------------------------
-- T1 | trf_dim_cliente   (SCD tipo 2)
-- Table input -> Dimension lookup/update -> (opcional) Table output de log
--   Dimension lookup/update:
--     Target table ........ dw.dim_cliente
--     Keys ................ cliente_id  <-  cliente_id
--     Technical key ....... cliente_sk (use "Use table maximum + 1")
--     Version field ....... versao
--     Date range .......... data_inicio / data_fim
--     Stream datefield .... deixe em branco (o PDI usa a data do sistema)
--     Fields tipo Insert (gera nova versão): endereco, bairro, cidade, pais, cep, ativo
--     Fields tipo Update (corrige sem versionar): nome, sobrenome, nome_completo, email,
--                                                 data_cadastro, loja_id
-- ---------------------------------------------------------------------
SELECT
    c.customer_id                           AS cliente_id,
    c.first_name                            AS nome,
    c.last_name                             AS sobrenome,
    c.first_name || ' ' || c.last_name      AS nome_completo,
    c.email                                 AS email,
    a.address                               AS endereco,
    a.district                              AS bairro,
    ci.city                                 AS cidade,
    co.country                              AS pais,
    a.postal_code                           AS cep,
    c.activebool                            AS ativo,
    c.create_date                           AS data_cadastro,
    c.store_id                              AS loja_id
FROM public.customer c
JOIN public.address  a  ON a.address_id  = c.address_id
JOIN public.city     ci ON ci.city_id    = a.city_id
JOIN public.country  co ON co.country_id = ci.country_id
ORDER BY c.customer_id;


-- ---------------------------------------------------------------------
-- T2 | trf_dim_filme   (SCD tipo 1: todos os campos como "Update")
-- Table input -> Dimension lookup/update
--   Keys: filme_id <- filme_id | Technical key: filme_sk | Version: versao
-- ---------------------------------------------------------------------
SELECT
    f.film_id                                   AS filme_id,
    f.title                                     AS titulo,
    f.description                               AS descricao,
    f.release_year                              AS ano_lancamento,
    trim(l.name)                                AS idioma,
    COALESCE(string_agg(DISTINCT cat.name, ', ' ORDER BY cat.name),
             'Sem categoria')                   AS categoria,
    f.rating::text                              AS classificacao,
    f.rental_duration                           AS duracao_locacao_dias,
    f.rental_rate                               AS valor_locacao,
    f.length                                    AS duracao_min,
    f.replacement_cost                          AS custo_reposicao
FROM public.film f
JOIN public.language l          ON l.language_id = f.language_id
LEFT JOIN public.film_category fc ON fc.film_id  = f.film_id
LEFT JOIN public.category cat   ON cat.category_id = fc.category_id
GROUP BY f.film_id, l.name
ORDER BY f.film_id;


-- ---------------------------------------------------------------------
-- T3 | trf_dim_loja   (SCD tipo 1 ou 2, à sua escolha)
-- Table input -> Dimension lookup/update
--   Keys: loja_id <- loja_id | Technical key: loja_sk | Version: versao
-- ---------------------------------------------------------------------
SELECT
    s.store_id                              AS loja_id,
    a.address                               AS endereco,
    a.district                              AS bairro,
    ci.city                                 AS cidade,
    co.country                              AS pais,
    st.first_name || ' ' || st.last_name    AS gerente
FROM public.store s
JOIN public.address a  ON a.address_id  = s.address_id
JOIN public.city    ci ON ci.city_id    = a.city_id
JOIN public.country co ON co.country_id = ci.country_id
JOIN public.staff   st ON st.staff_id   = s.manager_staff_id
ORDER BY s.store_id;


-- ---------------------------------------------------------------------
-- T4 | trf_fato_aluguel
-- Table input -> 3x "Dimension lookup/update" (modo lookup: desmarque
--   "Update the dimension?") -> Select values -> Table output (dw.fato_aluguel)
--
--   Lookup cliente: key cliente_id, stream datefield = rental_date,
--                   retorna cliente_sk   (pega a versão vigente na data do aluguel)
--   Lookup filme:   key filme_id,   retorna filme_sk
--   Lookup loja:    key loja_id,    retorna loja_sk
--
--   Select values: remover cliente_id, filme_id, loja_id, rental_date, return_date
--   Table output:  Truncate table marcado (carga full) ou use Job com
--                  "TRUNCATE TABLE dw.fato_aluguel" antes.
-- ---------------------------------------------------------------------
SELECT
    r.rental_id                                         AS aluguel_id,
    r.rental_date                                       AS rental_date,
    r.return_date                                       AS return_date,
    to_char(r.rental_date, 'YYYYMMDD')::int             AS data_aluguel_key,
    to_char(r.return_date, 'YYYYMMDD')::int             AS data_devolucao_key,  -- NULL se não devolvido
    r.customer_id                                       AS cliente_id,
    i.film_id                                           AS filme_id,
    i.store_id                                          AS loja_id,
    (r.return_date::date - r.rental_date::date)         AS dias_alugado,
    COALESCE(p.qtd_pagamentos, 0)                       AS qtd_pagamentos,
    COALESCE(p.valor_pago, 0)                           AS valor_pago
FROM public.rental r
JOIN public.inventory i ON i.inventory_id = r.inventory_id
LEFT JOIN (
    SELECT rental_id,
           count(*)    AS qtd_pagamentos,
           sum(amount) AS valor_pago
    FROM public.payment
    GROUP BY rental_id
) p ON p.rental_id = r.rental_id
ORDER BY r.rental_id;

-- Variante incremental (para evoluir depois): guarde o último last_update
-- carregado em uma tabela de controle e filtre assim:
--   WHERE r.last_update > ?     -- parâmetro vindo de "Table input" anterior


-- =====================================================================
-- VALIDAÇÃO (rodar depois do Job)
-- =====================================================================

-- 1) Contagens: origem x destino
SELECT 'rental'   AS origem, count(*) FROM public.rental
UNION ALL SELECT 'fato_aluguel', count(*) FROM dw.fato_aluguel
UNION ALL SELECT 'customer',     count(*) FROM public.customer
UNION ALL SELECT 'dim_cliente (versão atual, sem a linha 0)', count(*) FROM dw.dim_cliente WHERE data_fim > now() AND cliente_sk <> 0
UNION ALL SELECT 'film',         count(*) FROM public.film
UNION ALL SELECT 'dim_filme (sem a linha 0)', count(*) FROM dw.dim_filme WHERE filme_sk <> 0;

-- 2) Valor total: origem x destino
SELECT (SELECT sum(amount)     FROM public.payment)       AS total_origem,
       (SELECT sum(valor_pago) FROM dw.fato_aluguel)       AS total_dw;

-- 3) Consulta analítica de exemplo: receita por categoria e mês
SELECT d.ano, d.mes, f.categoria,
       count(*)           AS qtd_alugueis,
       sum(fa.valor_pago) AS receita
FROM dw.fato_aluguel fa
JOIN dw.dim_data  d ON d.data_key  = fa.data_aluguel_key
JOIN dw.dim_filme f ON f.filme_sk  = fa.filme_sk
GROUP BY d.ano, d.mes, f.categoria
ORDER BY d.ano, d.mes, receita DESC;

-- 4) Teste de SCD2: mude o endereço de um cliente na origem, rode a
--    trf_dim_cliente de novo e confira as duas versões:
--   UPDATE public.address SET address = 'Rua Nova, 123'
--    WHERE address_id = (SELECT address_id FROM public.customer WHERE customer_id = 1);
--   SELECT cliente_sk, versao, data_inicio, data_fim, endereco
--     FROM dw.dim_cliente WHERE cliente_id = 1 ORDER BY versao;
