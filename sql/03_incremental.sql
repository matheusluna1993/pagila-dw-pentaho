-- =====================================================================
-- 03_incremental.sql  |  Carga incremental da dw.fato_aluguel (padrão "watermark")
--
-- Ideia: guardar até quando já carregamos (dw.etl_controle) e, a cada execução,
-- ler da origem só o que mudou depois disso. A fato passa de "truncate + insert"
-- para "upsert" (Insert/Update), então reexecutar nunca duplica linhas.
--
-- Job final:
--   START -> trf_get_watermark -> trf_dim_cliente -> trf_dim_filme -> trf_dim_loja
--         -> trf_fato_aluguel (incremental) -> SQL (avança o watermark) -> Success
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1) TABELA DE CONTROLE  (rodar uma vez, no psql)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dw.etl_controle (
    tabela_destino  varchar(50)  PRIMARY KEY,
    ultima_carga    timestamptz  NOT NULL DEFAULT '1900-01-01 00:00:00+00',
    atualizado_em   timestamp
);

INSERT INTO dw.etl_controle (tabela_destino)
VALUES ('fato_aluguel')
ON CONFLICT (tabela_destino) DO NOTHING;


-- ---------------------------------------------------------------------
-- 2) ESTENDER A DIM_DATA  (rodar uma vez, no psql)
-- Aluguéis novos têm data de hoje; sem isso a FK da fato falha.
-- ---------------------------------------------------------------------
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
        (SELECT max(data) + 1 FROM dw.dim_data),
        date '2030-12-31',
        interval '1 day'
     ) AS d
ON CONFLICT (data_key) DO NOTHING;


-- ---------------------------------------------------------------------
-- 3) trf_get_watermark  |  Table input -> Set Variables
--    (marque "Replace variables in script?" = NÃO neste step)
--
--    Set Variables (categoria Job):
--      ultima_carga -> VAR_ULTIMA_CARGA   escopo: "Valid in the parent job"
--      nova_carga   -> VAR_NOVA_CARGA     escopo: "Valid in the parent job"
-- ---------------------------------------------------------------------
SELECT
    ultima_carga::text AS ultima_carga,
    now()::text        AS nova_carga
FROM dw.etl_controle
WHERE tabela_destino = 'fato_aluguel';


-- ---------------------------------------------------------------------
-- 4) trf_fato_aluguel  |  novo Table input (substitui a query T4)
--    Marque "Replace variables in script?" = SIM
--
--    Sobrou só o filtro WHERE em relação à T4. Ele pega:
--      a) aluguéis criados/alterados na janela (last_update), e
--      b) aluguéis que receberam pagamento na janela, porque a tabela
--         payment não atualiza o last_update do aluguel.
-- ---------------------------------------------------------------------
SELECT
    r.rental_id                                         AS aluguel_id,
    r.rental_date                                       AS rental_date,
    r.return_date                                       AS return_date,
    to_char(r.rental_date, 'YYYYMMDD')::int             AS data_aluguel_key,
    to_char(r.return_date, 'YYYYMMDD')::int             AS data_devolucao_key,
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
WHERE (
          r.last_update >  '${VAR_ULTIMA_CARGA}'::timestamptz
      AND r.last_update <= '${VAR_NOVA_CARGA}'::timestamptz
      )
   OR r.rental_id IN (
          SELECT pg.rental_id
          FROM public.payment pg
          WHERE pg.payment_date >  '${VAR_ULTIMA_CARGA}'::timestamptz
            AND pg.payment_date <= '${VAR_NOVA_CARGA}'::timestamptz
      )
ORDER BY r.rental_id;

-- Para rodar/preview a trf_fato_aluguel sozinha no Spoon, defina as variáveis em
-- Edit > Set Environment Variables:
--   VAR_ULTIMA_CARGA = 1900-01-01 00:00:00+00
--   VAR_NOVA_CARGA   = 2100-01-01 00:00:00+00
--
-- Depois do Select values (mesmas 9 colunas de antes), troque o Table output por
-- "Insert / Update" (categoria Output):
--   Target schema / table ... dw / fato_aluguel
--   The key(s) to look up ... Table field aluguel_id  =  Stream field aluguel_id
--   Update fields ........... data_aluguel_key, data_devolucao_key, cliente_sk,
--                             filme_sk, loja_sk, dias_alugado, qtd_pagamentos, valor_pago
--                             (Update = Y; aluguel_id fica com Update = N)
--   Commit size ............. 1000


-- ---------------------------------------------------------------------
-- 5) Entrada "SQL" do Job (General > SQL), ligada com hop VERDE após a
--    trf_fato_aluguel. Conexão pagila, marque "Use variable substitution?".
--    Só roda se tudo deu certo, então uma falha não avança o watermark.
-- ---------------------------------------------------------------------
UPDATE dw.etl_controle
   SET ultima_carga  = '${VAR_NOVA_CARGA}'::timestamptz,
       atualizado_em = now()
 WHERE tabela_destino = 'fato_aluguel';


-- ---------------------------------------------------------------------
-- 6) Recarga completa (reprocessar tudo): zere o watermark e rode o job
-- ---------------------------------------------------------------------
-- UPDATE dw.etl_controle SET ultima_carga = '1900-01-01 00:00:00+00'
--  WHERE tabela_destino = 'fato_aluguel';


-- =====================================================================
-- TESTES  (rodar no psql, rodando o job entre um teste e outro)
-- =====================================================================

-- A) Novo aluguel  -> deve aparecer 1 linha nova na fato
INSERT INTO public.rental (rental_date, inventory_id, customer_id, staff_id)
VALUES (now(), 1, 1, 1)
RETURNING rental_id;

-- B) Alteração de um aluguel existente -> a fato deve ATUALIZAR a linha (não duplicar)
UPDATE public.rental
   SET return_date = return_date + interval '1 day',
       last_update = now()
 WHERE rental_id = 1;


-- =====================================================================
-- VALIDAÇÃO
-- =====================================================================

-- Watermark avançou?
SELECT * FROM dw.etl_controle;

-- Origem x destino devem continuar iguais (sem duplicar)
SELECT (SELECT count(*) FROM public.rental)      AS origem,
       (SELECT count(*) FROM dw.fato_aluguel)    AS fato,
       (SELECT count(DISTINCT aluguel_id) FROM dw.fato_aluguel) AS fato_distintos;

-- Conferir o aluguel alterado no teste B
SELECT aluguel_id, data_devolucao_key, dias_alugado, valor_pago
  FROM dw.fato_aluguel
 WHERE aluguel_id = 1;
