-- =====================================================================
--  PLATAFORMA DE PALENQUES  ·  Esquema PostgreSQL 15 o superior
--  Multiempresa (RLS) · libro contable inmutable · quinielas · ventajas
--  referidos · temporadas · crédito y límites de pérdida
--
--  ESTADO: escrito sin poder ejecutarlo. Córrelo primero en una base de
--  pruebas y luego ejecuta 02_prueba_basica.sql para validarlo.
--
--  CONVENCIONES
--  * Dinero siempre NUMERIC(14,2), guardado en PESOS reales.
--    Los jugadores piden en UNIDADES (enteros o decimales, ej. 2.5). La unidad
--    vale tenants.factor_unidad pesos (por defecto 1000: 2.5 unidades = $2,500).
--    REGLA: todo lo que ENTRA a la base se convierte con a_pesos(); todo lo que
--    SALE para mostrar se convierte con a_unidades() (las vistas ya traen ambas).
--  * Saldo positivo = a favor del jugador. Negativo = el jugador debe.
--  * Los movimientos NUNCA se editan ni se borran: se revierten.
--  * Cada asiento contable suma exactamente cero (se valida al COMMIT).
--  * Cada petición del backend debe iniciar con:
--        SET LOCAL app.tenant_id  = '<id de la empresa>';
--        SET LOCAL app.usuario_id = '<id del usuario>';
-- =====================================================================

BEGIN;

-- =====================================================================
-- 1. EMPRESAS Y USUARIOS
-- =====================================================================
CREATE TABLE tenants (
  id                     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nombre                 TEXT    NOT NULL,
  subdominio             TEXT    NOT NULL UNIQUE,
  estado                 TEXT    NOT NULL DEFAULT 'activo'
                           CHECK (estado IN ('activo','suspendido','cancelado')),
  zona_horaria           TEXT    NOT NULL DEFAULT 'America/Mexico_City',
  factor_unidad          NUMERIC(10,2) NOT NULL DEFAULT 1000 CHECK (factor_unidad > 0),  -- pesos por unidad
  incremento_apuesta     NUMERIC(10,2) NOT NULL DEFAULT 10 CHECK (incremento_apuesta > 0), -- apuestas en múltiplos de esto (base favorito)
  corte_dia              TIME    NOT NULL DEFAULT '06:00',   -- el "día" operativo cambia a esta hora
  comision_pelea_pct     NUMERIC(5,2) NOT NULL DEFAULT 10 CHECK (comision_pelea_pct    BETWEEN 0 AND 100),
  comision_quiniela_pct  NUMERIC(5,2) NOT NULL DEFAULT 10 CHECK (comision_quiniela_pct BETWEEN 0 AND 100),
  comision_ventaja_pct   NUMERIC(5,2) NOT NULL DEFAULT 10 CHECK (comision_ventaja_pct  BETWEEN 0 AND 100),
  base_comision_pelea    TEXT    NOT NULL DEFAULT 'ganancia' CHECK (base_comision_pelea IN ('ganancia','pozo')),
  momios_permitidos      TEXT[]  NOT NULL DEFAULT ARRAY['parejo','100-90','100-80','100-70'],
  referidos_en_quinielas BOOLEAN NOT NULL DEFAULT FALSE,
  referidos_en_ventajas  BOOLEAN NOT NULL DEFAULT FALSE,
  created_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE usuarios (
  id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id  BIGINT NOT NULL REFERENCES tenants(id),
  email      TEXT   NOT NULL,
  nombre     TEXT   NOT NULL,
  rol        TEXT   NOT NULL CHECK (rol IN ('administrador','operador','cajero','capturista','lectura')),
  activo     BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, email)
);

CREATE TABLE jugadores (
  id                     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id              BIGINT NOT NULL REFERENCES tenants(id),
  usuario_id             BIGINT REFERENCES usuarios(id),          -- acceso al portal, si lo tiene
  nombre                 TEXT   NOT NULL,
  tipo_cuenta            TEXT   NOT NULL DEFAULT 'prepago' CHECK (tipo_cuenta IN ('prepago','credito')),
  limite_credito         NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (limite_credito >= 0),
  limite_perdida_evento  NUMERIC(14,2) CHECK (limite_perdida_evento > 0),   -- NULL = sin límite
  limite_perdida_diario  NUMERIC(14,2) CHECK (limite_perdida_diario > 0),
  ref_jugador_id         BIGINT,                                  -- "Ref": quién lo invitó
  ref_pct                NUMERIC(5,2) NOT NULL DEFAULT 0 CHECK (ref_pct BETWEEN 0 AND 100),
  estatus                TEXT   NOT NULL DEFAULT 'activo' CHECK (estatus IN ('activo','inactivo')),  -- solo 'activo' puede apostar
  -- Por qué está inactivo: 'credito' = se excedió el crédito con autorización del operador (se reactiva solo
  -- al volver a quedar dentro del crédito); 'manual' = lo inactivó una persona (solo una persona lo reactiva)
  inactivo_por           TEXT   CHECK (inactivo_por IN ('manual','credito')),
  created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (id, tenant_id),
  FOREIGN KEY (ref_jugador_id, tenant_id) REFERENCES jugadores (id, tenant_id),
  CHECK (ref_jugador_id IS DISTINCT FROM id),
  CHECK (estatus = 'inactivo' OR inactivo_por IS NULL),
  CHECK (tipo_cuenta = 'credito' OR limite_credito = 0)
);

CREATE TABLE limites_historial (
  id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id      BIGINT NOT NULL REFERENCES tenants(id),
  jugador_id     BIGINT NOT NULL REFERENCES jugadores(id),
  campo          TEXT   NOT NULL,
  valor_anterior TEXT,
  valor_nuevo    TEXT,
  usuario_id     BIGINT REFERENCES usuarios(id),
  motivo         TEXT,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE auditoria (
  id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id  BIGINT NOT NULL REFERENCES tenants(id),
  usuario_id BIGINT REFERENCES usuarios(id),
  accion     TEXT NOT NULL,
  entidad    TEXT,
  entidad_id BIGINT,
  detalle    JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =====================================================================
-- 2. TEMPORADAS, EVENTOS Y PARTIDOS
-- =====================================================================
CREATE TABLE temporadas (
  id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id BIGINT NOT NULL REFERENCES tenants(id),
  nombre    TEXT NOT NULL,
  inicio    DATE NOT NULL,
  fin       DATE,
  estado    TEXT NOT NULL DEFAULT 'abierta' CHECK (estado IN ('abierta','cerrada')),
  UNIQUE (id, tenant_id)
);
CREATE UNIQUE INDEX uq_temporada_abierta ON temporadas (tenant_id) WHERE estado = 'abierta';

CREATE TABLE eventos (
  id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id    BIGINT NOT NULL REFERENCES tenants(id),
  temporada_id BIGINT NOT NULL REFERENCES temporadas(id),
  nombre       TEXT NOT NULL,
  fecha        DATE NOT NULL,
  estado       TEXT NOT NULL DEFAULT 'abierto' CHECK (estado IN ('abierto','finalizado')),
  UNIQUE (id, tenant_id)
);

-- Un partido es un equipo/rancho del derby (ej. "Rancho La Vega") y tiene un número.
CREATE TABLE partidos (
  id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id BIGINT NOT NULL REFERENCES tenants(id),
  evento_id BIGINT NOT NULL REFERENCES eventos(id),
  numero    INT    NOT NULL CHECK (numero >= 0),
  nombre    TEXT   NOT NULL,
  UNIQUE (evento_id, numero)
);

-- =====================================================================
-- 3. LIBRO CONTABLE (partida doble, inmutable)
-- =====================================================================
CREATE TABLE cuentas (
  id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id  BIGINT NOT NULL REFERENCES tenants(id),
  tipo       TEXT   NOT NULL CHECK (tipo IN ('jugador','empresa','apertura')),
  jugador_id BIGINT UNIQUE REFERENCES jugadores(id),
  CHECK ((tipo = 'jugador') = (jugador_id IS NOT NULL))
);
CREATE UNIQUE INDEX uq_cuenta_por_tipo ON cuentas (tenant_id, tipo) WHERE tipo <> 'jugador';

CREATE TABLE asientos (
  id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id           BIGINT NOT NULL REFERENCES tenants(id),
  tipo                TEXT   NOT NULL,
  descripcion         TEXT,
  usuario_id          BIGINT REFERENCES usuarios(id),
  revierte_asiento_id BIGINT UNIQUE REFERENCES asientos(id),
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE movimientos (
  id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id    BIGINT NOT NULL REFERENCES tenants(id),
  asiento_id   BIGINT NOT NULL REFERENCES asientos(id),
  cuenta_id    BIGINT NOT NULL REFERENCES cuentas(id),
  temporada_id BIGINT NOT NULL REFERENCES temporadas(id),
  evento_id    BIGINT REFERENCES eventos(id),
  monto        NUMERIC(14,2) NOT NULL CHECK (monto <> 0),     -- + a favor de la cuenta, - en contra
  origen_tipo  TEXT NOT NULL CHECK (origen_tipo IN
                 ('abono','cargo','pelea','quiniela','ventaja','comision','referido','apertura','cierre')),
  origen_id    BIGINT,        -- quiniela: id de participación · ventaja: id de participante · referido: id de comisión
  concepto     TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_mov_cuenta   ON movimientos (cuenta_id);
CREATE INDEX ix_mov_asiento  ON movimientos (asiento_id);
CREATE INDEX ix_mov_temp     ON movimientos (tenant_id, temporada_id);
CREATE INDEX ix_mov_origen   ON movimientos (origen_tipo, origen_id);

-- =====================================================================
-- 4. PELEAS, OFERTAS Y EMPAREJAMIENTOS (funciones en la sección 11.5)
-- =====================================================================
CREATE TABLE peleas (
  id                    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id             BIGINT NOT NULL REFERENCES tenants(id),
  evento_id             BIGINT NOT NULL REFERENCES eventos(id),
  numero                INT    NOT NULL,
  partido_rojo_id       BIGINT REFERENCES partidos(id),
  partido_verde_id      BIGINT REFERENCES partidos(id),
  favorito              TEXT   NOT NULL DEFAULT 'ninguno' CHECK (favorito IN ('rojo','verde','ninguno')),
  favorito_definido_por BIGINT REFERENCES usuarios(id),
  favorito_definido_en  TIMESTAMPTZ,
  -- Ciclo de la pelea. El resultado se guarda aparte, en "resultado".
  estado                TEXT   NOT NULL DEFAULT 'programada' CHECK (estado IN
                          ('programada','apuestas_abiertas','apuestas_cerradas','en_curso','finalizada')),
  comision_pct          NUMERIC(5,2) NOT NULL CHECK (comision_pct BETWEEN 0 AND 100),
  base_comision         TEXT NOT NULL CHECK (base_comision IN ('ganancia','pozo')),
  -- ROJO / VERDE: ganó ese color · TABLAS: empate · CANCELADA: no se realizó
  -- NO_SE_CAZO: nunca hubo cuadre (se muestra como "NO SE CAZÓ")
  resultado             TEXT CHECK (resultado IN ('ROJO','VERDE','TABLAS','CANCELADA','NO_SE_CAZO')),
  asiento_id            BIGINT REFERENCES asientos(id),      -- solo si hubo movimiento de dinero (ROJO / VERDE)
  resuelta_por          BIGINT REFERENCES usuarios(id),
  resuelta_en           TIMESTAMPTZ,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (evento_id, numero),
  CHECK ((estado = 'finalizada') = (resultado IS NOT NULL))
);

-- Una oferta se expresa en "base favorito": es lo que arriesgaría el favorito.
--   riesgo del favorito / parejo    = base
--   riesgo del no favorito          = base x (90 | 80 | 70) / 100
-- Con la base en múltiplos del incremento, todos los emparejamientos dan montos exactos.
CREATE TABLE ofertas (
  id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id        BIGINT NOT NULL REFERENCES tenants(id),
  pelea_id         BIGINT NOT NULL REFERENCES peleas(id),
  jugador_id       BIGINT NOT NULL REFERENCES jugadores(id),
  lado             TEXT   NOT NULL CHECK (lado IN ('rojo','verde')),
  rol              TEXT   NOT NULL CHECK (rol IN ('favorito','no_favorito','parejo')),
  momio            TEXT   NOT NULL CHECK (momio IN ('parejo','100-90','100-80','100-70')),
  base_solicitada  NUMERIC(14,2) NOT NULL CHECK (base_solicitada > 0),
  base_emparejada  NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (base_emparejada >= 0),
  base_cancelada   NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (base_cancelada >= 0),
  monto_reservado  NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (monto_reservado >= 0),   -- dinero propio comprometido
  estado           TEXT   NOT NULL DEFAULT 'abierta' CHECK (estado IN
                     ('abierta','parcial','completa','cancelada','liquidada')),
  idempotency_key  UUID   NOT NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, idempotency_key),
  CHECK (base_emparejada + base_cancelada <= base_solicitada)
);
CREATE INDEX ix_ofertas_libro   ON ofertas (pelea_id, momio, lado, estado, id);
CREATE INDEX ix_ofertas_jugador ON ofertas (jugador_id) WHERE estado <> 'liquidada';

CREATE TABLE emparejamientos (
  id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id       BIGINT NOT NULL REFERENCES tenants(id),
  pelea_id        BIGINT NOT NULL REFERENCES peleas(id),
  oferta_rojo_id  BIGINT NOT NULL REFERENCES ofertas(id),
  oferta_verde_id BIGINT NOT NULL REFERENCES ofertas(id),
  monto_rojo      NUMERIC(14,2) NOT NULL CHECK (monto_rojo > 0),
  monto_verde     NUMERIC(14,2) NOT NULL CHECK (monto_verde > 0),
  momio           TEXT NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (oferta_rojo_id <> oferta_verde_id)
);

-- =====================================================================
-- 5. QUINIELAS (cada número es un PARTIDO; un número puede tener socios)
-- =====================================================================
CREATE TABLE quinielas (
  id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id        BIGINT NOT NULL REFERENCES tenants(id),
  evento_id        BIGINT NOT NULL REFERENCES eventos(id),
  numero           INT    NOT NULL CHECK (numero > 0),          -- el "1" de Q1-4
  nombre           TEXT,
  precio_numero    NUMERIC(14,2) NOT NULL CHECK (precio_numero > 0),   -- costo de CADA número
  comision_pct     NUMERIC(5,2) NOT NULL CHECK (comision_pct BETWEEN 0 AND 100),
  estado           TEXT NOT NULL DEFAULT 'abierta' CHECK (estado IN ('abierta','cerrada','resuelta','anulada')),
  asiento_id       BIGINT REFERENCES asientos(id),
  resuelta_por     BIGINT REFERENCES usuarios(id),
  resuelta_en      TIMESTAMPTZ,
  motivo_anulacion TEXT,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (evento_id, numero)
);

CREATE TABLE quiniela_participaciones (
  id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id   BIGINT NOT NULL REFERENCES tenants(id),
  quiniela_id BIGINT NOT NULL REFERENCES quinielas(id),
  partido_id  BIGINT NOT NULL REFERENCES partidos(id),         -- el "4" de Q1-4
  jugador_id  BIGINT NOT NULL REFERENCES jugadores(id),
  monto_parte NUMERIC(14,2) NOT NULL CHECK (monto_parte > 0),  -- su parte del costo (sociedad)
  es_ganador  BOOLEAN,
  neto        NUMERIC(14,2),                                   -- resultado al resolver (+ gana, - pierde)
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (quiniela_id, partido_id, jugador_id)
);
CREATE INDEX ix_qp_numero ON quiniela_participaciones (quiniela_id, partido_id);

CREATE TABLE quiniela_ganadores (
  quiniela_id BIGINT NOT NULL REFERENCES quinielas(id),
  partido_id  BIGINT NOT NULL REFERENCES partidos(id),
  PRIMARY KEY (quiniela_id, partido_id)
);

-- =====================================================================
-- 6. VENTAJAS (duelo de dos jugadores con el mismo importe)
-- =====================================================================
CREATE TABLE ventajas (
  id                 BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id          BIGINT NOT NULL REFERENCES tenants(id),
  evento_id          BIGINT NOT NULL REFERENCES eventos(id),
  numero             INT    NOT NULL CHECK (numero > 0),        -- el "1" de V1
  descripcion        TEXT,
  monto              NUMERIC(14,2) NOT NULL CHECK (monto > 0),
  comision_pct       NUMERIC(5,2) NOT NULL CHECK (comision_pct BETWEEN 0 AND 100),
  estado             TEXT NOT NULL DEFAULT 'abierta' CHECK (estado IN ('abierta','resuelta','anulada')),
  ganador_jugador_id BIGINT REFERENCES jugadores(id),
  asiento_id         BIGINT REFERENCES asientos(id),
  resuelta_por       BIGINT REFERENCES usuarios(id),
  resuelta_en        TIMESTAMPTZ,
  motivo_anulacion   TEXT,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (evento_id, numero)
);

CREATE TABLE ventaja_participantes (
  id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id  BIGINT NOT NULL REFERENCES tenants(id),
  ventaja_id BIGINT NOT NULL REFERENCES ventajas(id),
  jugador_id BIGINT NOT NULL REFERENCES jugadores(id),
  neto       NUMERIC(14,2),
  UNIQUE (ventaja_id, jugador_id)
);

-- =====================================================================
-- 7. REFERIDOS
-- =====================================================================
CREATE TABLE comisiones_referido (
  id                    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id             BIGINT NOT NULL REFERENCES tenants(id),
  origen_tipo           TEXT NOT NULL CHECK (origen_tipo IN ('pelea','quiniela','ventaja')),
  origen_id             BIGINT NOT NULL,
  invitado_id           BIGINT NOT NULL REFERENCES jugadores(id),
  referente_id          BIGINT NOT NULL REFERENCES jugadores(id),
  comision_base         NUMERIC(14,2) NOT NULL,         -- parte de la comisión de la empresa atribuible a este invitado
  pct_aplicado          NUMERIC(5,2)  NOT NULL,         -- ref_pct vigente al momento de resolver
  monto                 NUMERIC(14,2) NOT NULL CHECK (monto > 0),
  estado                TEXT NOT NULL DEFAULT 'devengada' CHECK (estado IN ('devengada','liberada','cancelada')),
  asiento_liberacion_id BIGINT REFERENCES asientos(id),
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  liberada_en           TIMESTAMPTZ
);
CREATE INDEX ix_ref_invitado ON comisiones_referido (invitado_id) WHERE estado = 'devengada';

-- =====================================================================
-- 8. TRIGGERS DE INTEGRIDAD
-- =====================================================================

-- 8.1 Los asientos y movimientos no se editan ni se borran
CREATE FUNCTION trg_inmutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'La tabla % es inmutable: registre una reversión en lugar de modificar', TG_TABLE_NAME;
END $$;

CREATE TRIGGER movimientos_inmutable BEFORE UPDATE OR DELETE ON movimientos
  FOR EACH ROW EXECUTE FUNCTION trg_inmutable();
CREATE TRIGGER asientos_inmutable BEFORE UPDATE OR DELETE ON asientos
  FOR EACH ROW EXECUTE FUNCTION trg_inmutable();
CREATE TRIGGER movimientos_sin_truncate BEFORE TRUNCATE ON movimientos
  FOR EACH STATEMENT EXECUTE FUNCTION trg_inmutable();

-- 8.2 Cada asiento debe sumar cero (se verifica al hacer COMMIT)
CREATE FUNCTION trg_asiento_balanceado() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_suma NUMERIC;
BEGIN
  SELECT SUM(monto) INTO v_suma FROM movimientos WHERE asiento_id = NEW.asiento_id;
  IF v_suma <> 0 THEN
    RAISE EXCEPTION 'El asiento % no suma cero (suma %)', NEW.asiento_id, v_suma;
  END IF;
  RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER movimientos_asiento_cero
  AFTER INSERT ON movimientos DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION trg_asiento_balanceado();

-- 8.3 Cuentas automáticas
CREATE FUNCTION trg_tenant_cuentas() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO cuentas (tenant_id, tipo) VALUES (NEW.id, 'empresa'), (NEW.id, 'apertura');
  RETURN NEW;
END $$;
CREATE TRIGGER tenants_cuentas AFTER INSERT ON tenants
  FOR EACH ROW EXECUTE FUNCTION trg_tenant_cuentas();

CREATE FUNCTION trg_jugador_cuenta() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO cuentas (tenant_id, tipo, jugador_id) VALUES (NEW.tenant_id, 'jugador', NEW.id);
  RETURN NEW;
END $$;
CREATE TRIGGER jugadores_cuenta AFTER INSERT ON jugadores
  FOR EACH ROW EXECUTE FUNCTION trg_jugador_cuenta();

-- 8.4 Referidos: sin ciclos (A invita a B y B invita a A)
CREATE FUNCTION trg_jugadores_sin_ciclos() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_actual BIGINT := NEW.ref_jugador_id; v_saltos INT := 0;
BEGIN
  WHILE v_actual IS NOT NULL LOOP
    IF v_actual = NEW.id THEN
      RAISE EXCEPTION 'Referencia circular entre jugadores';
    END IF;
    v_saltos := v_saltos + 1;
    EXIT WHEN v_saltos > 50;
    SELECT ref_jugador_id INTO v_actual FROM jugadores WHERE id = v_actual;
  END LOOP;
  RETURN NEW;
END $$;
CREATE TRIGGER jugadores_sin_ciclos BEFORE INSERT OR UPDATE OF ref_jugador_id ON jugadores
  FOR EACH ROW EXECUTE FUNCTION trg_jugadores_sin_ciclos();

-- 8.5 Historial automático de crédito, límites, referido y estatus
--     (el backend puede indicar el motivo con SET LOCAL app.motivo = '...')
CREATE FUNCTION trg_jugadores_historial() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE c TEXT; v_old JSONB := to_jsonb(OLD); v_new JSONB := to_jsonb(NEW);
BEGIN
  FOREACH c IN ARRAY ARRAY['tipo_cuenta','limite_credito','limite_perdida_evento',
                           'limite_perdida_diario','ref_jugador_id','ref_pct','estatus','inactivo_por'] LOOP
    IF v_old -> c IS DISTINCT FROM v_new -> c THEN
      INSERT INTO limites_historial (tenant_id, jugador_id, campo, valor_anterior, valor_nuevo, usuario_id, motivo)
      VALUES (NEW.tenant_id, NEW.id, c, v_old ->> c, v_new ->> c,
              NULLIF(current_setting('app.usuario_id', true), '')::bigint,
              NULLIF(current_setting('app.motivo', true), ''));
    END IF;
  END LOOP;
  RETURN NEW;
END $$;
CREATE TRIGGER jugadores_historial AFTER UPDATE ON jugadores
  FOR EACH ROW EXECUTE FUNCTION trg_jugadores_historial();

-- 8.5b Motivo de la inactividad: toda inactivación sin motivo es "manual"; al activar se limpia
CREATE FUNCTION trg_jugadores_estatus() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.estatus = 'activo' THEN
    NEW.inactivo_por := NULL;
  ELSIF NEW.inactivo_por IS NULL THEN
    NEW.inactivo_por := 'manual';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER jugadores_estatus BEFORE INSERT OR UPDATE OF estatus, inactivo_por ON jugadores
  FOR EACH ROW EXECUTE FUNCTION trg_jugadores_estatus();

-- 8.6 Comisión fijada al crear la pelea / quiniela / ventaja
CREATE FUNCTION trg_fijar_comision() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE t tenants%ROWTYPE;
BEGIN
  SELECT * INTO t FROM tenants WHERE id = NEW.tenant_id;
  IF NEW.comision_pct IS NULL THEN
    NEW.comision_pct := CASE TG_TABLE_NAME
      WHEN 'quinielas' THEN t.comision_quiniela_pct
      WHEN 'ventajas'  THEN t.comision_ventaja_pct
      ELSE t.comision_pelea_pct END;
  END IF;
  IF TG_TABLE_NAME = 'peleas' THEN
    IF NEW.base_comision IS NULL THEN
      NEW.base_comision := t.base_comision_pelea;
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER peleas_comision    BEFORE INSERT ON peleas    FOR EACH ROW EXECUTE FUNCTION trg_fijar_comision();
CREATE TRIGGER quinielas_comision BEFORE INSERT ON quinielas FOR EACH ROW EXECUTE FUNCTION trg_fijar_comision();
CREATE TRIGGER ventajas_comision  BEFORE INSERT ON ventajas  FOR EACH ROW EXECUTE FUNCTION trg_fijar_comision();

-- 8.7 El favorito solo se cambia mientras la pelea está "programada"
CREATE FUNCTION trg_peleas_favorito() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.favorito IS DISTINCT FROM OLD.favorito THEN
    IF OLD.estado <> 'programada' THEN
      RAISE EXCEPTION 'El favorito solo puede cambiarse cuando la pelea está programada';
    END IF;
    NEW.favorito_definido_en  := now();
    NEW.favorito_definido_por := NULLIF(current_setting('app.usuario_id', true), '')::bigint;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER peleas_favorito BEFORE UPDATE ON peleas
  FOR EACH ROW EXECUTE FUNCTION trg_peleas_favorito();

-- 8.8 Una ventaja admite exactamente dos jugadores
CREATE FUNCTION trg_ventaja_dos() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF (SELECT COUNT(*) FROM ventaja_participantes WHERE ventaja_id = NEW.ventaja_id) >= 2 THEN
    RAISE EXCEPTION 'Una ventaja admite exactamente dos jugadores';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER ventaja_max_dos BEFORE INSERT ON ventaja_participantes
  FOR EACH ROW EXECUTE FUNCTION trg_ventaja_dos();

-- =====================================================================
-- 9. FUNCIONES BASE: cuentas, saldos, reservas y validación de apuestas
-- =====================================================================
CREATE FUNCTION cuenta_jugador(p_jugador BIGINT) RETURNS BIGINT LANGUAGE sql STABLE AS $$
  SELECT id FROM cuentas WHERE jugador_id = p_jugador
$$;

CREATE FUNCTION cuenta_empresa(p_tenant BIGINT) RETURNS BIGINT LANGUAGE sql STABLE AS $$
  SELECT id FROM cuentas WHERE tenant_id = p_tenant AND tipo = 'empresa'
$$;

CREATE FUNCTION cuenta_apertura(p_tenant BIGINT) RETURNS BIGINT LANGUAGE sql STABLE AS $$
  SELECT id FROM cuentas WHERE tenant_id = p_tenant AND tipo = 'apertura'
$$;

CREATE FUNCTION temporada_abierta(p_tenant BIGINT) RETURNS BIGINT LANGUAGE plpgsql STABLE AS $$
DECLARE v_id BIGINT;
BEGIN
  SELECT id INTO v_id FROM temporadas WHERE tenant_id = p_tenant AND estado = 'abierta';
  IF v_id IS NULL THEN RAISE EXCEPTION 'No hay una temporada abierta'; END IF;
  RETURN v_id;
END $$;

-- Saldo acumulado de todas las temporadas (confirmado, sin reservas)
CREATE FUNCTION saldo_jugador(p_jugador BIGINT) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
  SELECT COALESCE(SUM(m.monto), 0)
  FROM movimientos m JOIN cuentas c ON c.id = m.cuenta_id
  WHERE c.jugador_id = p_jugador
$$;

-- Día operativo según la zona horaria y el corte de la empresa
CREATE FUNCTION dia_operacion(p_tenant BIGINT, p_ts TIMESTAMPTZ) RETURNS DATE LANGUAGE sql STABLE AS $$
  SELECT ((p_ts AT TIME ZONE t.zona_horaria) - t.corte_dia::interval)::date
  FROM tenants t WHERE t.id = p_tenant
$$;

-- Conversión de unidades (lo que piden los jugadores) a pesos (lo que se guarda).
-- Rechaza cantidades cuyo equivalente tenga más de 2 decimales en pesos.
CREATE FUNCTION a_pesos(p_tenant BIGINT, p_unidades NUMERIC) RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE v_factor NUMERIC; v_pesos NUMERIC;
BEGIN
  SELECT factor_unidad INTO v_factor FROM tenants WHERE id = p_tenant;
  IF v_factor IS NULL THEN RAISE EXCEPTION 'Empresa inexistente'; END IF;
  v_pesos := p_unidades * v_factor;
  IF v_pesos <> round(v_pesos, 2) THEN
    RAISE EXCEPTION '% unidades equivalen a % pesos: máximo 2 decimales en pesos', p_unidades, v_pesos;
  END IF;
  RETURN v_pesos;
END $$;

CREATE FUNCTION a_unidades(p_tenant BIGINT, p_pesos NUMERIC) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
  SELECT p_pesos / factor_unidad FROM tenants WHERE id = p_tenant
$$;

-- Dinero comprometido en juegos que aún no se resuelven (peleas, quinielas, ventajas)
CREATE FUNCTION reservado_jugador(p_jugador BIGINT, p_evento BIGINT DEFAULT NULL)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
  SELECT
    COALESCE((SELECT SUM(o.monto_reservado)
                FROM ofertas o JOIN peleas pe ON pe.id = o.pelea_id
               WHERE o.jugador_id = p_jugador
                 AND o.estado <> 'liquidada'
                 AND (p_evento IS NULL OR pe.evento_id = p_evento)), 0)
  + COALESCE((SELECT SUM(qp.monto_parte)
                FROM quiniela_participaciones qp JOIN quinielas q ON q.id = qp.quiniela_id
               WHERE qp.jugador_id = p_jugador
                 AND q.estado IN ('abierta','cerrada')
                 AND (p_evento IS NULL OR q.evento_id = p_evento)), 0)
  + COALESCE((SELECT SUM(v.monto)
                FROM ventaja_participantes vp JOIN ventajas v ON v.id = vp.ventaja_id
               WHERE vp.jugador_id = p_jugador
                 AND v.estado = 'abierta'
                 AND (p_evento IS NULL OR v.evento_id = p_evento)), 0)
$$;

-- Pérdida neta (pérdidas menos ganancias) de juegos, por evento y/o por día operativo
CREATE FUNCTION perdida_neta(p_jugador BIGINT, p_evento BIGINT DEFAULT NULL, p_dia DATE DEFAULT NULL)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
  SELECT COALESCE(-SUM(m.monto), 0)
  FROM movimientos m JOIN cuentas c ON c.id = m.cuenta_id
  WHERE c.jugador_id = p_jugador
    AND m.origen_tipo IN ('pelea','quiniela','ventaja')
    AND (p_evento IS NULL OR m.evento_id = p_evento)
    AND (p_dia IS NULL OR dia_operacion(m.tenant_id, m.created_at) = p_dia)
$$;

-- Proyección de una apuesta nueva, sin modificar nada. La usa validar_apuesta y sirve a la
-- pantalla para armar el aviso "Crédito excedido" (crédito, saldo, en juego, monto nuevo y
-- pérdida proyectada).
--   poder de apuesta   = saldo + crédito - en juego
--   pérdida proyectada = max(0, en juego + monto nuevo - saldo)
CREATE FUNCTION proyeccion_apuesta(p_jugador BIGINT, p_evento BIGINT, p_monto NUMERIC)
RETURNS JSONB LANGUAGE plpgsql STABLE AS $$
DECLARE j jugadores%ROWTYPE; v_saldo NUMERIC; v_res NUMERIC; v_poder NUMERIC; v_pev NUMERIC; v_pdia NUMERIC;
BEGIN
  SELECT * INTO j FROM jugadores WHERE id = p_jugador;
  IF NOT FOUND THEN RAISE EXCEPTION 'Jugador inexistente'; END IF;

  v_saldo := saldo_jugador(p_jugador);
  v_res   := reservado_jugador(p_jugador);
  v_poder := v_saldo + j.limite_credito - v_res;
  v_pev   := GREATEST(perdida_neta(p_jugador, p_evento), 0) + reservado_jugador(p_jugador, p_evento) + p_monto;
  v_pdia  := GREATEST(perdida_neta(p_jugador, NULL, dia_operacion(j.tenant_id, now())), 0) + v_res + p_monto;

  RETURN jsonb_build_object(
    'estatus', j.estatus, 'tipo_cuenta', j.tipo_cuenta,
    'limite_credito', j.limite_credito, 'saldo', v_saldo, 'en_juego', v_res,
    'monto_nuevo', p_monto, 'poder_apuesta', v_poder,
    'perdida_proyectada', GREATEST(0, v_res + p_monto - v_saldo),
    'excede_credito', p_monto > v_poder,
    'limite_perdida_evento', j.limite_perdida_evento, 'perdida_evento_proyectada', v_pev,
    'excede_evento', j.limite_perdida_evento IS NOT NULL AND v_pev > j.limite_perdida_evento,
    'limite_perdida_diario', j.limite_perdida_diario, 'perdida_diaria_proyectada', v_pdia,
    'excede_diario', j.limite_perdida_diario IS NOT NULL AND v_pdia > j.limite_perdida_diario);
END $$;

-- Valida una apuesta nueva. Bloquea la fila del jugador para que dos apuestas simultáneas no
-- se salten el saldo ni los límites.
--   * Empresa o jugador inactivo: nunca puede apostar.
--   * Límites de pérdida por evento / día: bloqueo duro (el operador los ajusta en el jugador).
--   * Prepago: nunca puede exceder su saldo.
--   * Crédito excedido: lanza SQLSTATE 'PX001' con el detalle en JSON (campo DETAIL) para que la
--     pantalla pregunte al operador. Un administrador u operador lo autoriza repitiendo la
--     llamada con p_autorizar_exceso = TRUE y su id: la apuesta se acepta y el jugador queda
--     INACTIVO (inactivo_por = 'credito'), con constancia en historial y auditoría.
CREATE FUNCTION validar_apuesta(p_jugador BIGINT, p_evento BIGINT, p_monto NUMERIC,
                                p_autorizar_exceso BOOLEAN DEFAULT FALSE, p_usuario BIGINT DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
  j jugadores%ROWTYPE; t tenants%ROWTYPE; v_p JSONB; v_rol TEXT; v_old_u TEXT; v_old_m TEXT;
BEGIN
  IF p_monto IS NULL OR p_monto <= 0 THEN RAISE EXCEPTION 'Monto inválido'; END IF;

  SELECT * INTO j FROM jugadores WHERE id = p_jugador FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Jugador inexistente'; END IF;
  SELECT * INTO t FROM tenants WHERE id = j.tenant_id;

  IF t.estado <> 'activo' THEN RAISE EXCEPTION 'La empresa no está activa (renta pendiente)'; END IF;
  IF j.estatus <> 'activo' THEN RAISE EXCEPTION 'El jugador está inactivo y no puede apostar'; END IF;

  v_p := proyeccion_apuesta(p_jugador, p_evento, p_monto);

  IF (v_p ->> 'excede_evento')::boolean THEN
    RAISE EXCEPTION 'Excede el límite de pérdida por evento (%)', j.limite_perdida_evento;
  END IF;
  IF (v_p ->> 'excede_diario')::boolean THEN
    RAISE EXCEPTION 'Excede el límite de pérdida diario (%)', j.limite_perdida_diario;
  END IF;

  IF NOT (v_p ->> 'excede_credito')::boolean THEN RETURN; END IF;

  IF j.tipo_cuenta = 'prepago' THEN
    RAISE EXCEPTION 'Saldo insuficiente: disponible %, requerido %', v_p ->> 'poder_apuesta', p_monto;
  END IF;

  IF NOT p_autorizar_exceso THEN
    RAISE EXCEPTION USING ERRCODE = 'PX001',
                          MESSAGE = 'Crédito excedido: requiere autorización del operador',
                          DETAIL  = v_p::text;
  END IF;

  SELECT rol INTO v_rol FROM usuarios WHERE id = p_usuario AND tenant_id = j.tenant_id AND activo;
  IF v_rol IS NULL OR v_rol NOT IN ('administrador','operador') THEN
    RAISE EXCEPTION 'Sin permiso para autorizar un exceso de crédito';
  END IF;

  v_old_u := current_setting('app.usuario_id', true);
  v_old_m := current_setting('app.motivo', true);
  PERFORM set_config('app.usuario_id', p_usuario::text, true);
  PERFORM set_config('app.motivo', 'Crédito excedido: apuesta autorizada por el operador', true);
  UPDATE jugadores SET estatus = 'inactivo', inactivo_por = 'credito' WHERE id = p_jugador;
  PERFORM set_config('app.usuario_id', COALESCE(v_old_u, ''), true);
  PERFORM set_config('app.motivo',     COALESCE(v_old_m, ''), true);

  INSERT INTO auditoria (tenant_id, usuario_id, accion, entidad, entidad_id, detalle)
  VALUES (j.tenant_id, p_usuario, 'exceso_credito_autorizado', 'jugador', p_jugador, v_p);
END $$;

-- Reactiva solo a quien fue inactivado POR CRÉDITO cuando vuelve a quedar dentro de su crédito
-- (poder de apuesta >= 0, o sea: deuda proyectada <= crédito). Nunca reactiva a quien se
-- inactivó a mano.
CREATE FUNCTION evaluar_reactivacion(p_jugador BIGINT) RETURNS BOOLEAN LANGUAGE plpgsql AS $$
DECLARE j jugadores%ROWTYPE; v_old_m TEXT;
BEGIN
  SELECT * INTO j FROM jugadores WHERE id = p_jugador;
  IF NOT FOUND OR j.estatus <> 'inactivo' OR j.inactivo_por IS DISTINCT FROM 'credito'
     OR j.limite_credito <= 0 THEN
    RETURN FALSE;
  END IF;
  IF saldo_jugador(p_jugador) + j.limite_credito - reservado_jugador(p_jugador) >= 0 THEN
    v_old_m := current_setting('app.motivo', true);
    PERFORM set_config('app.motivo', 'Reactivado automáticamente: volvió a quedar dentro de su crédito', true);
    UPDATE jugadores SET estatus = 'activo' WHERE id = p_jugador;
    PERFORM set_config('app.motivo', COALESCE(v_old_m, ''), true);
    RETURN TRUE;
  END IF;
  RETURN FALSE;
END $$;

-- Se llama cada vez que cambia el saldo o lo reservado de un jugador
CREATE FUNCTION evaluar_jugador(p_jugador BIGINT) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  PERFORM evaluar_reactivacion(p_jugador);
  PERFORM evaluar_liberacion_referidos(p_jugador);
END $$;

-- =====================================================================
-- 10. FUNCIONES DEL LIBRO: asientos, reversiones, abonos y cargos
-- =====================================================================
CREATE FUNCTION nuevo_asiento(p_tenant BIGINT, p_tipo TEXT, p_desc TEXT, p_usuario BIGINT,
                              p_revierte BIGINT DEFAULT NULL)
RETURNS BIGINT LANGUAGE sql AS $$
  INSERT INTO asientos (tenant_id, tipo, descripcion, usuario_id, revierte_asiento_id)
  VALUES (p_tenant, p_tipo, p_desc, p_usuario, p_revierte)
  RETURNING id
$$;

-- Revierte un asiento completo con movimientos contrarios (en la temporada abierta)
CREATE FUNCTION reversar_asiento(p_asiento BIGINT, p_motivo TEXT, p_usuario BIGINT)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE a asientos%ROWTYPE; v_nuevo BIGINT; v_temp BIGINT; r RECORD;
BEGIN
  SELECT * INTO a FROM asientos WHERE id = p_asiento FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Asiento inexistente'; END IF;
  IF a.revierte_asiento_id IS NOT NULL THEN RAISE EXCEPTION 'No se puede revertir una reversión'; END IF;
  IF EXISTS (SELECT 1 FROM asientos WHERE revierte_asiento_id = p_asiento) THEN
    RAISE EXCEPTION 'El asiento % ya fue revertido', p_asiento;
  END IF;
  IF COALESCE(p_motivo, '') = '' THEN RAISE EXCEPTION 'El motivo es obligatorio'; END IF;

  v_temp  := temporada_abierta(a.tenant_id);
  v_nuevo := nuevo_asiento(a.tenant_id, 'reversion', p_motivo, p_usuario, p_asiento);

  INSERT INTO movimientos (tenant_id, asiento_id, cuenta_id, temporada_id, evento_id,
                           monto, origen_tipo, origen_id, concepto)
  SELECT tenant_id, v_nuevo, cuenta_id, v_temp, evento_id,
         -monto, origen_tipo, origen_id, 'Reversión: ' || p_motivo
  FROM movimientos WHERE asiento_id = p_asiento;

  -- El saldo de estos jugadores cambió: puede liberar corretajes o reactivarlos
  FOR r IN SELECT DISTINCT c.jugador_id FROM movimientos m JOIN cuentas c ON c.id = m.cuenta_id
            WHERE m.asiento_id = p_asiento AND c.jugador_id IS NOT NULL
  LOOP
    PERFORM evaluar_jugador(r.jugador_id);
  END LOOP;

  RETURN v_nuevo;
END $$;

-- Abono (depósito o pago del jugador) o cargo (retiro u otro cobro)
CREATE FUNCTION registrar_caja(p_jugador BIGINT, p_tipo TEXT, p_monto NUMERIC,
                               p_concepto TEXT, p_usuario BIGINT)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE j jugadores%ROWTYPE; v_as BIGINT; v_signo INT; v_temp BIGINT;
BEGIN
  IF p_tipo NOT IN ('abono','cargo') THEN RAISE EXCEPTION 'Tipo inválido: use abono o cargo'; END IF;
  IF p_monto IS NULL OR p_monto <= 0 THEN RAISE EXCEPTION 'Monto inválido'; END IF;

  SELECT * INTO j FROM jugadores WHERE id = p_jugador FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Jugador inexistente'; END IF;

  -- Un prepago no puede retirar más de lo que tiene disponible
  IF p_tipo = 'cargo' AND j.tipo_cuenta = 'prepago'
     AND saldo_jugador(p_jugador) - reservado_jugador(p_jugador) < p_monto THEN
    RAISE EXCEPTION 'Saldo disponible insuficiente para el cargo';
  END IF;

  v_signo := CASE p_tipo WHEN 'abono' THEN 1 ELSE -1 END;
  v_temp  := temporada_abierta(j.tenant_id);
  v_as    := nuevo_asiento(j.tenant_id, p_tipo, p_concepto, p_usuario);

  INSERT INTO movimientos (tenant_id, asiento_id, cuenta_id, temporada_id, monto, origen_tipo, concepto)
  VALUES (j.tenant_id, v_as, cuenta_jugador(p_jugador),        v_temp,  v_signo * p_monto, p_tipo, p_concepto),
         (j.tenant_id, v_as, cuenta_empresa(j.tenant_id),      v_temp, -v_signo * p_monto, p_tipo, p_concepto);

  PERFORM evaluar_jugador(p_jugador);
  RETURN v_as;
END $$;

-- =====================================================================
-- 11. REFERIDOS: devengar, liberar (saldo total >= 0) y cancelar
-- =====================================================================
-- p_comision = parte de la comisión de la empresa atribuible a este invitado ganador
CREATE FUNCTION devengar_referido(p_tenant BIGINT, p_origen TEXT, p_origen_id BIGINT,
                                  p_invitado BIGINT, p_comision NUMERIC)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE j jugadores%ROWTYPE; v_monto NUMERIC;
BEGIN
  SELECT * INTO j FROM jugadores WHERE id = p_invitado;
  IF j.ref_jugador_id IS NULL OR j.ref_pct <= 0 OR p_comision IS NULL OR p_comision <= 0 THEN RETURN; END IF;
  v_monto := round(p_comision * j.ref_pct / 100, 2);
  IF v_monto <= 0 THEN RETURN; END IF;
  INSERT INTO comisiones_referido (tenant_id, origen_tipo, origen_id, invitado_id, referente_id,
                                   comision_base, pct_aplicado, monto)
  VALUES (p_tenant, p_origen, p_origen_id, p_invitado, j.ref_jugador_id, p_comision, j.ref_pct, v_monto);
END $$;

-- Idempotente: libera todo lo devengado del invitado si su saldo total es >= 0
CREATE FUNCTION evaluar_liberacion_referidos(p_jugador BIGINT) RETURNS INT LANGUAGE plpgsql AS $$
DECLARE r comisiones_referido%ROWTYPE; v_as BIGINT; v_temp BIGINT; v_n INT := 0;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM comisiones_referido WHERE invitado_id = p_jugador AND estado = 'devengada') THEN
    RETURN 0;
  END IF;
  IF saldo_jugador(p_jugador) < 0 THEN RETURN 0; END IF;

  FOR r IN SELECT * FROM comisiones_referido
            WHERE invitado_id = p_jugador AND estado = 'devengada' ORDER BY id FOR UPDATE
  LOOP
    v_temp := temporada_abierta(r.tenant_id);
    v_as   := nuevo_asiento(r.tenant_id, 'referido', 'Corretaje liberado', NULL);
    INSERT INTO movimientos (tenant_id, asiento_id, cuenta_id, temporada_id, monto, origen_tipo, origen_id, concepto)
    VALUES (r.tenant_id, v_as, cuenta_empresa(r.tenant_id),        v_temp, -r.monto, 'referido', r.id, 'Pago de corretaje'),
           (r.tenant_id, v_as, cuenta_jugador(r.referente_id),     v_temp,  r.monto, 'referido', r.id, 'Corretaje de referido');
    UPDATE comisiones_referido
       SET estado = 'liberada', asiento_liberacion_id = v_as, liberada_en = now()
     WHERE id = r.id;
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $$;

-- Al anular un juego: lo devengado se cancela y lo ya liberado se revierte
CREATE FUNCTION cancelar_referidos(p_origen TEXT, p_origen_id BIGINT, p_motivo TEXT, p_usuario BIGINT)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE r comisiones_referido%ROWTYPE;
BEGIN
  FOR r IN SELECT * FROM comisiones_referido
            WHERE origen_tipo = p_origen AND origen_id = p_origen_id AND estado <> 'cancelada' FOR UPDATE
  LOOP
    IF r.estado = 'liberada' THEN
      PERFORM reversar_asiento(r.asiento_liberacion_id, p_motivo, p_usuario);
    END IF;
    UPDATE comisiones_referido SET estado = 'cancelada' WHERE id = r.id;
  END LOOP;
END $$;

-- =====================================================================
-- 11.5 PELEAS: ofertas, emparejamiento y los 5 resultados
--   ROJO / VERDE : se paga lo emparejado; la comisión sale de la ganancia (o del pozo)
--   TABLAS       : empate, no se mueve dinero ni se cobra comisión
--   CANCELADA    : no se realizó, no se mueve dinero ni se cobra comisión
--   NO_SE_CAZO   : nunca hubo cuadre (ninguna apuesta emparejada)
-- =====================================================================

-- Fracción que arriesga cada rol respecto a la base del favorito
CREATE FUNCTION factor_rol(p_momio TEXT, p_rol TEXT) RETURNS NUMERIC LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_rol = 'no_favorito' THEN
           CASE p_momio WHEN '100-90' THEN 0.9 WHEN '100-80' THEN 0.8 WHEN '100-70' THEN 0.7 ELSE 1 END
         ELSE 1 END
$$;

CREATE FUNCTION etiqueta_resultado(p_resultado TEXT) RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_resultado
           WHEN 'NO_SE_CAZO' THEN 'NO SE CAZÓ'
           WHEN 'ROJO' THEN 'ROJO' WHEN 'VERDE' THEN 'VERDE'
           WHEN 'TABLAS' THEN 'TABLAS' WHEN 'CANCELADA' THEN 'CANCELADA'
           ELSE 'PENDIENTE' END
$$;

-- Recalcula estado y dinero reservado de una oferta a partir de sus bases
CREATE FUNCTION oferta_refrescar(p_oferta BIGINT) RETURNS VOID LANGUAGE sql AS $$
  UPDATE ofertas SET
    monto_reservado = CASE WHEN estado = 'liquidada' THEN 0
                           ELSE round((base_solicitada - base_cancelada) * factor_rol(momio, rol), 2) END,
    estado = CASE WHEN estado = 'liquidada' THEN estado
                  WHEN base_emparejada = 0 AND base_cancelada >= base_solicitada THEN 'cancelada'
                  WHEN base_emparejada + base_cancelada >= base_solicitada THEN 'completa'
                  WHEN base_emparejada > 0 THEN 'parcial'
                  ELSE 'abierta' END
  WHERE id = p_oferta
$$;

CREATE FUNCTION pelea_abrir_apuestas(p_pelea BIGINT) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE pe peleas%ROWTYPE;
BEGIN
  SELECT * INTO pe FROM peleas WHERE id = p_pelea FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pelea inexistente'; END IF;
  IF pe.estado <> 'programada' THEN RAISE EXCEPTION 'La pelea % no está programada', pe.numero; END IF;
  IF (SELECT estado FROM eventos WHERE id = pe.evento_id) <> 'abierto' THEN
    RAISE EXCEPTION 'El evento está finalizado';
  END IF;
  UPDATE peleas SET estado = 'apuestas_abiertas' WHERE id = p_pelea;
END $$;

-- Crea una oferta y la empareja de inmediato contra el lado contrario, mismo momio,
-- en orden de llegada (parciales incluidos). Nunca empareja a un jugador contra sí mismo.
--   p_base : monto en "base favorito", múltiplo de tenants.incremento_apuesta
--   p_clave: UUID del cliente; una repetición (doble clic, reintento) devuelve la misma oferta
CREATE FUNCTION oferta_crear(p_pelea BIGINT, p_jugador BIGINT, p_lado TEXT, p_momio TEXT,
                             p_base NUMERIC, p_clave UUID,
                             p_autorizar_exceso BOOLEAN DEFAULT FALSE, p_usuario BIGINT DEFAULT NULL)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
  pe peleas%ROWTYPE; t tenants%ROWTYPE; o ofertas%ROWTYPE;
  v_rol TEXT; v_id BIGINT; v_rem NUMERIC; v_otro NUMERIC; v_m NUMERIC; v_lado_op TEXT;
  v_rol_rojo TEXT; v_rol_verde TEXT;
BEGIN
  SELECT * INTO pe FROM peleas WHERE id = p_pelea FOR UPDATE;      -- serializa el cuadre de esta pelea
  IF NOT FOUND THEN RAISE EXCEPTION 'Pelea inexistente'; END IF;

  SELECT id INTO v_id FROM ofertas WHERE tenant_id = pe.tenant_id AND idempotency_key = p_clave;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;

  IF p_lado NOT IN ('rojo','verde') THEN RAISE EXCEPTION 'Lado inválido: use rojo o verde'; END IF;
  IF pe.estado <> 'apuestas_abiertas' THEN
    RAISE EXCEPTION 'Las apuestas de la pelea % no están abiertas', pe.numero;
  END IF;

  SELECT * INTO t FROM tenants WHERE id = pe.tenant_id;
  IF NOT (p_momio = ANY (t.momios_permitidos)) THEN RAISE EXCEPTION 'Momio no permitido: %', p_momio; END IF;

  IF p_momio = 'parejo' THEN
    v_rol := 'parejo';
  ELSE
    IF pe.favorito = 'ninguno' THEN
      RAISE EXCEPTION 'La pelea % es pareja: solo admite el momio parejo', pe.numero;
    END IF;
    v_rol := CASE WHEN p_lado = pe.favorito THEN 'favorito' ELSE 'no_favorito' END;
  END IF;

  IF p_base IS NULL OR p_base <= 0 OR mod(p_base, t.incremento_apuesta) <> 0 THEN
    RAISE EXCEPTION 'El monto debe ser un múltiplo de % pesos', t.incremento_apuesta;
  END IF;

  PERFORM validar_apuesta(p_jugador, pe.evento_id, round(p_base * factor_rol(p_momio, v_rol), 2),
                          p_autorizar_exceso, p_usuario);

  INSERT INTO ofertas (tenant_id, pelea_id, jugador_id, lado, rol, momio,
                       base_solicitada, monto_reservado, idempotency_key)
  VALUES (pe.tenant_id, p_pelea, p_jugador, p_lado, v_rol, p_momio,
          p_base, round(p_base * factor_rol(p_momio, v_rol), 2), p_clave)
  RETURNING id INTO v_id;

  v_lado_op := CASE p_lado WHEN 'rojo' THEN 'verde' ELSE 'rojo' END;
  v_rem := p_base;

  FOR o IN SELECT * FROM ofertas
            WHERE pelea_id = p_pelea AND momio = p_momio AND lado = v_lado_op
              AND estado IN ('abierta','parcial') AND jugador_id <> p_jugador
            ORDER BY id FOR UPDATE
  LOOP
    EXIT WHEN v_rem <= 0;
    v_otro := o.base_solicitada - o.base_emparejada - o.base_cancelada;
    v_m := LEAST(v_rem, v_otro);
    IF v_m > 0 THEN
      v_rol_rojo  := CASE WHEN p_lado = 'rojo'  THEN v_rol ELSE o.rol END;
      v_rol_verde := CASE WHEN p_lado = 'verde' THEN v_rol ELSE o.rol END;
      INSERT INTO emparejamientos (tenant_id, pelea_id, oferta_rojo_id, oferta_verde_id,
                                   monto_rojo, monto_verde, momio)
      VALUES (pe.tenant_id, p_pelea,
              CASE WHEN p_lado = 'rojo'  THEN v_id ELSE o.id END,
              CASE WHEN p_lado = 'verde' THEN v_id ELSE o.id END,
              round(v_m * factor_rol(p_momio, v_rol_rojo), 2),
              round(v_m * factor_rol(p_momio, v_rol_verde), 2), p_momio);
      UPDATE ofertas SET base_emparejada = base_emparejada + v_m WHERE id = o.id;
      PERFORM oferta_refrescar(o.id);
      v_rem := v_rem - v_m;
    END IF;
  END LOOP;

  UPDATE ofertas SET base_emparejada = p_base - v_rem WHERE id = v_id;
  PERFORM oferta_refrescar(v_id);
  RETURN v_id;
END $$;

-- Cancela solo la parte NO emparejada de una oferta (mientras las apuestas están abiertas)
CREATE FUNCTION oferta_cancelar(p_oferta BIGINT) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE o ofertas%ROWTYPE; pe peleas%ROWTYPE;
BEGIN
  SELECT * INTO o FROM ofertas WHERE id = p_oferta;
  IF NOT FOUND THEN RAISE EXCEPTION 'Oferta inexistente'; END IF;
  SELECT * INTO pe FROM peleas WHERE id = o.pelea_id FOR UPDATE;
  IF pe.estado <> 'apuestas_abiertas' THEN
    RAISE EXCEPTION 'Solo se puede cancelar mientras las apuestas están abiertas';
  END IF;
  UPDATE ofertas SET base_cancelada = base_solicitada - base_emparejada WHERE id = p_oferta;
  PERFORM oferta_refrescar(p_oferta);
  PERFORM evaluar_jugador(o.jugador_id);
END $$;

-- Cierra apuestas: lo que no encontró contraparte NO juega y se libera el saldo reservado
CREATE FUNCTION pelea_cerrar_apuestas(p_pelea BIGINT) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE pe peleas%ROWTYPE; r RECORD;
BEGIN
  SELECT * INTO pe FROM peleas WHERE id = p_pelea FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pelea inexistente'; END IF;
  IF pe.estado <> 'apuestas_abiertas' THEN
    RAISE EXCEPTION 'Las apuestas de la pelea % no están abiertas', pe.numero;
  END IF;
  UPDATE ofertas SET base_cancelada = base_solicitada - base_emparejada
   WHERE pelea_id = p_pelea AND estado IN ('abierta','parcial');
  FOR r IN SELECT id FROM ofertas WHERE pelea_id = p_pelea LOOP
    PERFORM oferta_refrescar(r.id);
  END LOOP;
  FOR r IN SELECT DISTINCT jugador_id FROM ofertas WHERE pelea_id = p_pelea LOOP
    PERFORM evaluar_jugador(r.jugador_id);
  END LOOP;
  UPDATE peleas SET estado = 'apuestas_cerradas' WHERE id = p_pelea;
END $$;

-- Registra el resultado. Cada emparejamiento paga su parte:
--   ganador recibe lo que arriesgó el perdedor menos la comisión · perdedor pierde lo suyo
--   comisión = % sobre la ganancia del ganador (o sobre el pozo, según base_comision de la pelea)
CREATE FUNCTION pelea_registrar_resultado(p_pelea BIGINT, p_resultado TEXT, p_usuario BIGINT)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
  pe peleas%ROWTYPE; r RECORD; v_n INT; v_as BIGINT; v_temp BIGINT;
  v_gana BIGINT; v_pierde BIGINT; v_perdida NUMERIC; v_comision NUMERIC;
BEGIN
  IF p_resultado NOT IN ('ROJO','VERDE','TABLAS','CANCELADA','NO_SE_CAZO') THEN
    RAISE EXCEPTION 'Resultado inválido: %', p_resultado;
  END IF;

  SELECT * INTO pe FROM peleas WHERE id = p_pelea FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pelea inexistente'; END IF;
  IF pe.estado = 'finalizada' THEN
    RAISE EXCEPTION 'La pelea % ya tiene resultado (%)', pe.numero, etiqueta_resultado(pe.resultado);
  END IF;
  IF pe.estado NOT IN ('apuestas_cerradas','en_curso') THEN
    RAISE EXCEPTION 'Cierra las apuestas de la pelea % antes de registrar el resultado', pe.numero;
  END IF;
  IF (SELECT estado FROM eventos WHERE id = pe.evento_id) <> 'abierto' THEN
    RAISE EXCEPTION 'El evento está finalizado';
  END IF;

  SELECT COUNT(*) INTO v_n FROM emparejamientos WHERE pelea_id = p_pelea;
  IF p_resultado = 'NO_SE_CAZO' AND v_n > 0 THEN
    RAISE EXCEPTION 'La pelea % tiene apuestas emparejadas: no puede ser NO SE CAZÓ (use CANCELADA)', pe.numero;
  END IF;
  IF p_resultado IN ('ROJO','VERDE') AND v_n = 0 THEN
    RAISE EXCEPTION 'La pelea % no tiene jugadores en ambos colores: márcala como NO SE CAZÓ', pe.numero;
  END IF;

  IF p_resultado IN ('ROJO','VERDE') THEN
    v_temp := temporada_abierta(pe.tenant_id);
    v_as   := nuevo_asiento(pe.tenant_id, 'pelea', 'Resultado pelea ' || pe.numero || ': ' || p_resultado, p_usuario);

    FOR r IN SELECT e.id, e.monto_rojo, e.monto_verde, o1.jugador_id AS j_rojo, o2.jugador_id AS j_verde
               FROM emparejamientos e
               JOIN ofertas o1 ON o1.id = e.oferta_rojo_id
               JOIN ofertas o2 ON o2.id = e.oferta_verde_id
              WHERE e.pelea_id = p_pelea ORDER BY e.id
    LOOP
      IF p_resultado = 'ROJO' THEN
        v_gana := r.j_rojo;  v_pierde := r.j_verde; v_perdida := r.monto_verde;
      ELSE
        v_gana := r.j_verde; v_pierde := r.j_rojo;  v_perdida := r.monto_rojo;
      END IF;

      v_comision := round(CASE WHEN pe.base_comision = 'pozo' THEN r.monto_rojo + r.monto_verde
                               ELSE v_perdida END * pe.comision_pct / 100, 2);
      IF v_comision >= v_perdida THEN
        RAISE EXCEPTION 'La comisión (%) iguala o supera la ganancia del emparejamiento %', v_comision, r.id;
      END IF;

      INSERT INTO movimientos (tenant_id, asiento_id, cuenta_id, temporada_id, evento_id,
                               monto, origen_tipo, origen_id, concepto)
      VALUES (pe.tenant_id, v_as, cuenta_jugador(v_gana),   v_temp, pe.evento_id, v_perdida - v_comision, 'pelea', r.id, 'Ganancia'),
             (pe.tenant_id, v_as, cuenta_jugador(v_pierde), v_temp, pe.evento_id, -v_perdida,             'pelea', r.id, 'Pérdida');
      IF v_comision > 0 THEN
        INSERT INTO movimientos (tenant_id, asiento_id, cuenta_id, temporada_id, evento_id,
                                 monto, origen_tipo, origen_id, concepto)
        VALUES (pe.tenant_id, v_as, cuenta_empresa(pe.tenant_id), v_temp, pe.evento_id,
                v_comision, 'comision', r.id, 'Comisión pelea ' || pe.numero);
      END IF;

      PERFORM devengar_referido(pe.tenant_id, 'pelea', p_pelea, v_gana, v_comision);
    END LOOP;
  END IF;

  -- En cualquier resultado se libera todo el dinero reservado de la pelea
  UPDATE ofertas SET estado = 'liquidada', monto_reservado = 0 WHERE pelea_id = p_pelea;

  UPDATE peleas
     SET resultado = p_resultado, estado = 'finalizada', asiento_id = v_as,
         resuelta_por = p_usuario, resuelta_en = now()
   WHERE id = p_pelea;

  FOR r IN SELECT DISTINCT jugador_id FROM ofertas WHERE pelea_id = p_pelea LOOP
    PERFORM evaluar_jugador(r.jugador_id);
  END LOOP;

  RETURN v_as;     -- NULL cuando no hubo movimiento de dinero
END $$;

-- Corrige un resultado: revierte el dinero, cancela corretajes y deja la pelea lista
-- para registrar el resultado correcto. Queda constancia en la auditoría.
CREATE FUNCTION pelea_anular_resultado(p_pelea BIGINT, p_motivo TEXT, p_usuario BIGINT)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE pe peleas%ROWTYPE; r RECORD;
BEGIN
  SELECT * INTO pe FROM peleas WHERE id = p_pelea FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pelea inexistente'; END IF;
  IF pe.estado <> 'finalizada' THEN RAISE EXCEPTION 'La pelea % no tiene resultado que anular', pe.numero; END IF;
  IF COALESCE(p_motivo, '') = '' THEN RAISE EXCEPTION 'El motivo es obligatorio'; END IF;
  IF (SELECT estado FROM eventos WHERE id = pe.evento_id) <> 'abierto' THEN
    RAISE EXCEPTION 'El evento está finalizado: reactívalo antes de corregir';
  END IF;

  IF pe.asiento_id IS NOT NULL THEN
    PERFORM reversar_asiento(pe.asiento_id, p_motivo, p_usuario);
    PERFORM cancelar_referidos('pelea', p_pelea, p_motivo, p_usuario);
  END IF;

  -- Las ofertas vuelven a reservar su dinero hasta que se registre el nuevo resultado
  UPDATE ofertas SET estado = 'abierta' WHERE pelea_id = p_pelea AND estado = 'liquidada';
  FOR r IN SELECT id FROM ofertas WHERE pelea_id = p_pelea LOOP
    PERFORM oferta_refrescar(r.id);
  END LOOP;

  UPDATE peleas
     SET resultado = NULL, estado = 'apuestas_cerradas', asiento_id = NULL,
         resuelta_por = NULL, resuelta_en = NULL
   WHERE id = p_pelea;

  INSERT INTO auditoria (tenant_id, usuario_id, accion, entidad, entidad_id, detalle)
  VALUES (pe.tenant_id, p_usuario, 'anular_resultado', 'pelea', p_pelea,
          jsonb_build_object('motivo', p_motivo, 'resultado_anterior', pe.resultado));
END $$;

-- =====================================================================
-- 12. QUINIELAS
-- =====================================================================
-- Reparte el costo del número en partes iguales entre los socios.
-- El último socio absorbe el centavo sobrante.
CREATE FUNCTION quiniela_repartir(p_quiniela BIGINT, p_partido BIGINT) RETURNS VOID LANGUAGE sql AS $$
  WITH q AS (SELECT precio_numero AS precio FROM quinielas WHERE id = p_quiniela),
       m AS (SELECT id, row_number() OVER (ORDER BY id) AS rn, count(*) OVER () AS n
               FROM quiniela_participaciones
              WHERE quiniela_id = p_quiniela AND partido_id = p_partido)
  UPDATE quiniela_participaciones p
     SET monto_parte = CASE WHEN m.rn = m.n
                            THEN q.precio - round(q.precio / m.n, 2) * (m.n - 1)
                            ELSE round(q.precio / m.n, 2) END
    FROM m, q
   WHERE p.id = m.id
$$;

-- Anota a un jugador en un número (partido). Si el número ya tiene dueño, entra como socio.
CREATE FUNCTION quiniela_agregar(p_quiniela BIGINT, p_partido BIGINT, p_jugador BIGINT,
                                 p_autorizar_exceso BOOLEAN DEFAULT FALSE, p_usuario BIGINT DEFAULT NULL)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE q quinielas%ROWTYPE; v_n INT; v_id BIGINT;
BEGIN
  SELECT * INTO q FROM quinielas WHERE id = p_quiniela FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Quiniela inexistente'; END IF;
  IF q.estado <> 'abierta' THEN RAISE EXCEPTION 'La quiniela Q% no está abierta', q.numero; END IF;
  IF (SELECT estado FROM eventos WHERE id = q.evento_id) <> 'abierto' THEN
    RAISE EXCEPTION 'El evento está finalizado';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM partidos WHERE id = p_partido AND evento_id = q.evento_id) THEN
    RAISE EXCEPTION 'El partido no pertenece al evento de la quiniela';
  END IF;
  IF EXISTS (SELECT 1 FROM quiniela_participaciones
              WHERE quiniela_id = p_quiniela AND partido_id = p_partido AND jugador_id = p_jugador) THEN
    RAISE EXCEPTION 'El jugador ya está anotado en ese número de la quiniela Q%', q.numero;
  END IF;

  SELECT COUNT(*) INTO v_n FROM quiniela_participaciones
   WHERE quiniela_id = p_quiniela AND partido_id = p_partido;

  -- Su parte futura (el costo se dividirá entre v_n + 1 socios)
  PERFORM validar_apuesta(p_jugador, q.evento_id, round(q.precio_numero / (v_n + 1), 2),
                          p_autorizar_exceso, p_usuario);

  INSERT INTO quiniela_participaciones (tenant_id, quiniela_id, partido_id, jugador_id, monto_parte)
  VALUES (q.tenant_id, p_quiniela, p_partido, p_jugador, q.precio_numero)
  RETURNING id INTO v_id;

  PERFORM quiniela_repartir(p_quiniela, p_partido);
  RETURN v_id;
END $$;

CREATE FUNCTION quiniela_quitar(p_participacion BIGINT) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE qp quiniela_participaciones%ROWTYPE; q quinielas%ROWTYPE;
BEGIN
  SELECT * INTO qp FROM quiniela_participaciones WHERE id = p_participacion;
  IF NOT FOUND THEN RAISE EXCEPTION 'Participación inexistente'; END IF;
  SELECT * INTO q FROM quinielas WHERE id = qp.quiniela_id FOR UPDATE;
  IF q.estado <> 'abierta' THEN RAISE EXCEPTION 'Solo se puede quitar un jugador de una quiniela abierta'; END IF;
  DELETE FROM quiniela_participaciones WHERE id = p_participacion;
  PERFORM quiniela_repartir(qp.quiniela_id, qp.partido_id);
  PERFORM evaluar_jugador(qp.jugador_id);
END $$;

CREATE FUNCTION quiniela_cerrar_venta(p_quiniela BIGINT) RETURNS VOID LANGUAGE sql AS $$
  UPDATE quinielas SET estado = 'cerrada' WHERE id = p_quiniela AND estado = 'abierta'
$$;

-- El administrador marca uno o varios partidos ganadores.
--   pozo     = (números vendidos) x precio
--   comisión = pozo x comision_pct
--   premio por número ganador = (pozo - comisión) / ganadores, truncado a centavos
--   neto del número ganador   = premio - costo, repartido en partes iguales entre sus socios
--   los demás números pierden su parte
-- Los centavos sobrantes quedan en la empresa, por eso el asiento siempre suma cero.
CREATE FUNCTION quiniela_resolver(p_quiniela BIGINT, p_partidos_ganadores BIGINT[], p_usuario BIGINT)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
  q quinielas%ROWTYPE; t tenants%ROWTYPE; r RECORD;
  v_gan BIGINT[]; v_k INT; v_numeros INT; v_precio NUMERIC;
  v_pozo NUMERIC; v_comision NUMERIC; v_premio NUMERIC; v_empresa NUMERIC;
  v_as BIGINT; v_temp BIGINT;
BEGIN
  SELECT * INTO q FROM quinielas WHERE id = p_quiniela FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Quiniela inexistente'; END IF;
  IF q.estado NOT IN ('abierta','cerrada') THEN
    RAISE EXCEPTION 'La quiniela Q% ya está %', q.numero, q.estado;
  END IF;
  IF (SELECT estado FROM eventos WHERE id = q.evento_id) <> 'abierto' THEN
    RAISE EXCEPTION 'El evento está finalizado';
  END IF;
  SELECT * INTO t FROM tenants WHERE id = q.tenant_id;

  SELECT ARRAY(SELECT DISTINCT x FROM unnest(p_partidos_ganadores) AS x) INTO v_gan;
  v_k := COALESCE(cardinality(v_gan), 0);
  IF v_k = 0 THEN RAISE EXCEPTION 'Marca al menos un número ganador'; END IF;

  IF EXISTS (SELECT 1 FROM unnest(v_gan) AS g
              WHERE NOT EXISTS (SELECT 1 FROM quiniela_participaciones
                                 WHERE quiniela_id = p_quiniela AND partido_id = g)) THEN
    RAISE EXCEPTION 'Un número ganador no tiene jugadores en esta quiniela';
  END IF;

  v_precio := q.precio_numero;
  SELECT COUNT(DISTINCT partido_id) INTO v_numeros
    FROM quiniela_participaciones WHERE quiniela_id = p_quiniela;

  v_pozo     := v_numeros * v_precio;
  v_comision := round(v_pozo * q.comision_pct / 100, 2);
  v_premio   := trunc((v_pozo - v_comision) / v_k, 2);

  -- DECISIÓN PENDIENTE: el programa actual recorta a cero; aquí se bloquea
  -- porque un recorte rompería la regla de que todo suma cero.
  IF v_premio < v_precio THEN
    RAISE EXCEPTION 'El premio por número (%) sería menor a su costo (%). Revisa los ganadores o anula la quiniela',
                    v_premio, v_precio;
  END IF;

  -- Resultado por participación (socios en partes iguales, el último absorbe el centavo)
  WITH m AS (
    SELECT id, partido_id,
           row_number() OVER (PARTITION BY partido_id ORDER BY id) AS rn,
           count(*)     OVER (PARTITION BY partido_id)             AS n
      FROM quiniela_participaciones WHERE quiniela_id = p_quiniela)
  UPDATE quiniela_participaciones p
     SET es_ganador = (p.partido_id = ANY (v_gan)),
         neto = CASE
                  WHEN p.partido_id = ANY (v_gan) THEN
                    CASE WHEN m.rn = m.n
                         THEN (v_premio - v_precio) - round((v_premio - v_precio) / m.n, 2) * (m.n - 1)
                         ELSE round((v_premio - v_precio) / m.n, 2) END
                  ELSE -p.monto_parte
                END
    FROM m WHERE p.id = m.id;

  v_temp := temporada_abierta(q.tenant_id);
  v_as   := nuevo_asiento(q.tenant_id, 'quiniela', 'Resultado Q' || q.numero, p_usuario);

  INSERT INTO movimientos (tenant_id, asiento_id, cuenta_id, temporada_id, evento_id,
                           monto, origen_tipo, origen_id, concepto)
  SELECT q.tenant_id, v_as, cuenta_jugador(qp.jugador_id), v_temp, q.evento_id,
         qp.neto, 'quiniela', qp.id,
         CASE WHEN qp.es_ganador THEN 'Premio' ELSE 'Pérdida' END
    FROM quiniela_participaciones qp
   WHERE qp.quiniela_id = p_quiniela AND qp.neto <> 0;

  SELECT -COALESCE(SUM(neto), 0) INTO v_empresa
    FROM quiniela_participaciones WHERE quiniela_id = p_quiniela;

  IF v_empresa <> 0 THEN
    INSERT INTO movimientos (tenant_id, asiento_id, cuenta_id, temporada_id, evento_id,
                             monto, origen_tipo, origen_id, concepto)
    VALUES (q.tenant_id, v_as, cuenta_empresa(q.tenant_id), v_temp, q.evento_id,
            v_empresa, 'comision', p_quiniela, 'Comisión Q' || q.numero);
  END IF;

  INSERT INTO quiniela_ganadores (quiniela_id, partido_id) SELECT p_quiniela, unnest(v_gan);

  UPDATE quinielas
     SET estado = 'resuelta', asiento_id = v_as, resuelta_por = p_usuario, resuelta_en = now()
   WHERE id = p_quiniela;

  -- Referidos (si la empresa los activó para quinielas). La comisión se atribuye a cada
  -- ganador en proporción a su premio bruto. REGLA PROPUESTA: confírmala.
  IF t.referidos_en_quinielas THEN
    FOR r IN SELECT jugador_id, neto + monto_parte AS bruto
               FROM quiniela_participaciones WHERE quiniela_id = p_quiniela AND es_ganador
    LOOP
      PERFORM devengar_referido(q.tenant_id, 'quiniela', p_quiniela, r.jugador_id,
                                round(v_empresa * r.bruto / (v_k * v_premio), 2));
    END LOOP;
  END IF;

  FOR r IN SELECT DISTINCT jugador_id FROM quiniela_participaciones WHERE quiniela_id = p_quiniela
  LOOP
    PERFORM evaluar_jugador(r.jugador_id);
  END LOOP;

  RETURN v_as;
END $$;

CREATE FUNCTION quiniela_anular(p_quiniela BIGINT, p_motivo TEXT, p_usuario BIGINT)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE q quinielas%ROWTYPE; r RECORD;
BEGIN
  SELECT * INTO q FROM quinielas WHERE id = p_quiniela FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Quiniela inexistente'; END IF;
  IF q.estado = 'anulada' THEN RAISE EXCEPTION 'La quiniela ya está anulada'; END IF;
  IF COALESCE(p_motivo, '') = '' THEN RAISE EXCEPTION 'El motivo es obligatorio'; END IF;
  IF (SELECT estado FROM eventos WHERE id = q.evento_id) <> 'abierto' THEN
    RAISE EXCEPTION 'El evento está finalizado: reactívalo antes de anular';
  END IF;

  IF q.estado = 'resuelta' THEN
    PERFORM reversar_asiento(q.asiento_id, p_motivo, p_usuario);
    PERFORM cancelar_referidos('quiniela', q.id, p_motivo, p_usuario);
  END IF;

  UPDATE quinielas SET estado = 'anulada', motivo_anulacion = p_motivo WHERE id = p_quiniela;
  FOR r IN SELECT DISTINCT jugador_id FROM quiniela_participaciones WHERE quiniela_id = p_quiniela LOOP
    PERFORM evaluar_jugador(r.jugador_id);
  END LOOP;
END $$;

-- =====================================================================
-- 13. VENTAJAS
-- =====================================================================
CREATE FUNCTION ventaja_agregar(p_ventaja BIGINT, p_jugador BIGINT,
                                p_autorizar_exceso BOOLEAN DEFAULT FALSE, p_usuario BIGINT DEFAULT NULL)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v ventajas%ROWTYPE; v_id BIGINT;
BEGIN
  SELECT * INTO v FROM ventajas WHERE id = p_ventaja FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Ventaja inexistente'; END IF;
  IF v.estado <> 'abierta' THEN RAISE EXCEPTION 'La ventaja V% no está abierta', v.numero; END IF;
  IF (SELECT estado FROM eventos WHERE id = v.evento_id) <> 'abierto' THEN
    RAISE EXCEPTION 'El evento está finalizado';
  END IF;
  IF EXISTS (SELECT 1 FROM ventaja_participantes WHERE ventaja_id = p_ventaja AND jugador_id = p_jugador) THEN
    RAISE EXCEPTION 'El jugador ya está en la ventaja V%', v.numero;
  END IF;

  PERFORM validar_apuesta(p_jugador, v.evento_id, v.monto, p_autorizar_exceso, p_usuario);

  INSERT INTO ventaja_participantes (tenant_id, ventaja_id, jugador_id)
  VALUES (v.tenant_id, p_ventaja, p_jugador) RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- Ganador: recibe el importe del rival menos la comisión. Perdedor: pierde su importe.
CREATE FUNCTION ventaja_resolver(p_ventaja BIGINT, p_ganador BIGINT, p_usuario BIGINT)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
  v ventajas%ROWTYPE; t tenants%ROWTYPE;
  v_monto NUMERIC; v_comision NUMERIC; v_premio NUMERIC; v_as BIGINT; v_temp BIGINT; r RECORD;
BEGIN
  SELECT * INTO v FROM ventajas WHERE id = p_ventaja FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Ventaja inexistente'; END IF;
  IF v.estado <> 'abierta' THEN RAISE EXCEPTION 'La ventaja V% ya está %', v.numero, v.estado; END IF;
  IF (SELECT estado FROM eventos WHERE id = v.evento_id) <> 'abierto' THEN
    RAISE EXCEPTION 'El evento está finalizado';
  END IF;
  IF (SELECT COUNT(*) FROM ventaja_participantes WHERE ventaja_id = p_ventaja) <> 2 THEN
    RAISE EXCEPTION 'La ventaja V% necesita exactamente dos jugadores', v.numero;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM ventaja_participantes WHERE ventaja_id = p_ventaja AND jugador_id = p_ganador) THEN
    RAISE EXCEPTION 'El ganador no participa en la ventaja V%', v.numero;
  END IF;
  SELECT * INTO t FROM tenants WHERE id = v.tenant_id;

  v_monto    := v.monto;
  v_comision := round(v_monto * v.comision_pct / 100, 2);
  v_premio   := v_monto - v_comision;

  UPDATE ventaja_participantes
     SET neto = CASE WHEN jugador_id = p_ganador THEN v_premio ELSE -v_monto END
   WHERE ventaja_id = p_ventaja;

  v_temp := temporada_abierta(v.tenant_id);
  v_as   := nuevo_asiento(v.tenant_id, 'ventaja', 'Resultado V' || v.numero, p_usuario);

  INSERT INTO movimientos (tenant_id, asiento_id, cuenta_id, temporada_id, evento_id,
                           monto, origen_tipo, origen_id, concepto)
  SELECT v.tenant_id, v_as, cuenta_jugador(vp.jugador_id), v_temp, v.evento_id,
         vp.neto, 'ventaja', vp.id,
         CASE WHEN vp.jugador_id = p_ganador THEN 'Premio' ELSE 'Pérdida' END
    FROM ventaja_participantes vp WHERE vp.ventaja_id = p_ventaja;

  IF v_comision > 0 THEN
    INSERT INTO movimientos (tenant_id, asiento_id, cuenta_id, temporada_id, evento_id,
                             monto, origen_tipo, origen_id, concepto)
    VALUES (v.tenant_id, v_as, cuenta_empresa(v.tenant_id), v_temp, v.evento_id,
            v_comision, 'comision', p_ventaja, 'Comisión V' || v.numero);
  END IF;

  UPDATE ventajas
     SET estado = 'resuelta', ganador_jugador_id = p_ganador, asiento_id = v_as,
         resuelta_por = p_usuario, resuelta_en = now()
   WHERE id = p_ventaja;

  IF t.referidos_en_ventajas THEN
    PERFORM devengar_referido(v.tenant_id, 'ventaja', p_ventaja, p_ganador, v_comision);
  END IF;
  FOR r IN SELECT jugador_id FROM ventaja_participantes WHERE ventaja_id = p_ventaja LOOP
    PERFORM evaluar_jugador(r.jugador_id);
  END LOOP;

  RETURN v_as;
END $$;

CREATE FUNCTION ventaja_anular(p_ventaja BIGINT, p_motivo TEXT, p_usuario BIGINT)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE v ventajas%ROWTYPE; r RECORD;
BEGIN
  SELECT * INTO v FROM ventajas WHERE id = p_ventaja FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Ventaja inexistente'; END IF;
  IF v.estado = 'anulada' THEN RAISE EXCEPTION 'La ventaja ya está anulada'; END IF;
  IF COALESCE(p_motivo, '') = '' THEN RAISE EXCEPTION 'El motivo es obligatorio'; END IF;
  IF (SELECT estado FROM eventos WHERE id = v.evento_id) <> 'abierto' THEN
    RAISE EXCEPTION 'El evento está finalizado: reactívalo antes de anular';
  END IF;

  IF v.estado = 'resuelta' THEN
    PERFORM reversar_asiento(v.asiento_id, p_motivo, p_usuario);
    PERFORM cancelar_referidos('ventaja', v.id, p_motivo, p_usuario);
  END IF;

  UPDATE ventajas SET estado = 'anulada', motivo_anulacion = p_motivo WHERE id = p_ventaja;
  FOR r IN SELECT jugador_id FROM ventaja_participantes WHERE ventaja_id = p_ventaja LOOP
    PERFORM evaluar_jugador(r.jugador_id);
  END LOOP;
END $$;

-- =====================================================================
-- 14. CIERRE DE TEMPORADA
--   Cada jugador con saldo recibe una línea "Saldo inicial" en la temporada nueva.
--   La temporada vieja lleva una línea "cierre" que lo compensa, así el saldo
--   total del jugador no cambia y el estado de cuenta nunca recorre toda la historia.
-- =====================================================================
CREATE FUNCTION cerrar_temporada(p_temporada BIGINT, p_nombre_nueva TEXT, p_inicio_nueva DATE, p_usuario BIGINT)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE tmp temporadas%ROWTYPE; v_nueva BIGINT; v_as BIGINT; v_ap BIGINT;
BEGIN
  SELECT * INTO tmp FROM temporadas WHERE id = p_temporada FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Temporada inexistente'; END IF;
  IF tmp.estado <> 'abierta' THEN RAISE EXCEPTION 'La temporada ya está cerrada'; END IF;
  IF EXISTS (SELECT 1 FROM eventos WHERE temporada_id = p_temporada AND estado = 'abierto') THEN
    RAISE EXCEPTION 'Hay eventos abiertos en la temporada: finalízalos antes de cerrarla';
  END IF;

  v_ap := cuenta_apertura(tmp.tenant_id);
  UPDATE temporadas SET estado = 'cerrada', fin = COALESCE(fin, p_inicio_nueva - 1) WHERE id = p_temporada;
  INSERT INTO temporadas (tenant_id, nombre, inicio) VALUES (tmp.tenant_id, p_nombre_nueva, p_inicio_nueva)
    RETURNING id INTO v_nueva;

  v_as := nuevo_asiento(tmp.tenant_id, 'cierre_temporada', 'Cierre de ' || tmp.nombre, p_usuario);

  WITH s AS (
    SELECT c.id AS cuenta_id, SUM(m.monto) AS saldo
      FROM cuentas c JOIN movimientos m ON m.cuenta_id = c.id
     WHERE c.tenant_id = tmp.tenant_id AND c.tipo = 'jugador'
     GROUP BY c.id HAVING SUM(m.monto) <> 0)
  INSERT INTO movimientos (tenant_id, asiento_id, cuenta_id, temporada_id, monto, origen_tipo, concepto)
  SELECT tmp.tenant_id, v_as, x.cuenta, x.temp_id, x.monto, x.origen, x.concepto
    FROM s CROSS JOIN LATERAL (VALUES
      (s.cuenta_id, p_temporada, -s.saldo, 'cierre',   'Cierre de temporada'),
      (v_ap,        p_temporada,  s.saldo, 'cierre',   'Cierre de temporada'),
      (s.cuenta_id, v_nueva,      s.saldo, 'apertura', 'Saldo inicial'),
      (v_ap,        v_nueva,     -s.saldo, 'apertura', 'Saldo inicial')
    ) AS x(cuenta, temp_id, monto, origen, concepto);

  RETURN v_nueva;
END $$;

-- =====================================================================
-- 15. ESTADO DE CUENTA
--   El código Q1-4 / V1 se arma aquí; no se guarda como texto.
-- =====================================================================
CREATE VIEW v_estado_cuenta WITH (security_invoker = true) AS
SELECT m.tenant_id, c.jugador_id, m.temporada_id, m.evento_id, m.id AS movimiento_id, m.created_at,
       CASE m.origen_tipo
         WHEN 'quiniela' THEN 'Q' || q.numero || '-' || pa.numero
         WHEN 'ventaja'  THEN 'V' || v.numero
         WHEN 'pelea'    THEN 'Pelea ' || pe.numero
         WHEN 'abono'    THEN 'Abono'
         WHEN 'cargo'    THEN 'Cargo'
         WHEN 'referido' THEN 'Ref'
         WHEN 'apertura' THEN 'Saldo inicial'
         WHEN 'cierre'   THEN 'Cierre'
         ELSE m.origen_tipo
       END AS codigo,
       pa.nombre AS partido,
       m.concepto, m.monto,
       SUM(m.monto) OVER (PARTITION BY c.jugador_id ORDER BY m.created_at, m.id) AS saldo_acumulado,
       a_unidades(m.tenant_id, m.monto) AS monto_unidades,
       a_unidades(m.tenant_id, SUM(m.monto) OVER (PARTITION BY c.jugador_id ORDER BY m.created_at, m.id)) AS saldo_acumulado_unidades
  FROM movimientos m
  JOIN cuentas c ON c.id = m.cuenta_id AND c.tipo = 'jugador'
  LEFT JOIN quiniela_participaciones qp ON m.origen_tipo = 'quiniela' AND qp.id = m.origen_id
  LEFT JOIN quinielas q                 ON q.id = qp.quiniela_id
  LEFT JOIN partidos pa                 ON pa.id = qp.partido_id
  LEFT JOIN ventaja_participantes vp    ON m.origen_tipo = 'ventaja' AND vp.id = m.origen_id
  LEFT JOIN ventajas v                  ON v.id = vp.ventaja_id
  LEFT JOIN emparejamientos em          ON m.origen_tipo = 'pelea' AND em.id = m.origen_id
  LEFT JOIN peleas pe                   ON pe.id = em.pelea_id;

-- Resumen por temporada: saldo inicial + resultado - cargos + abonos = saldo final
CREATE VIEW v_resumen_temporada WITH (security_invoker = true) AS
SELECT m.tenant_id, c.jugador_id, m.temporada_id,
       COALESCE(SUM(m.monto) FILTER (WHERE m.origen_tipo = 'apertura'), 0)                         AS saldo_inicial,
       COALESCE(SUM(m.monto) FILTER (WHERE m.origen_tipo IN ('pelea','quiniela','ventaja')), 0)   AS resultado_juegos,
       COALESCE(SUM(m.monto) FILTER (WHERE m.origen_tipo = 'referido'), 0)                         AS corretaje,
       COALESCE(SUM(m.monto) FILTER (WHERE m.origen_tipo = 'cargo'), 0)                            AS cargos,
       COALESCE(SUM(m.monto) FILTER (WHERE m.origen_tipo = 'abono'), 0)                            AS abonos,
       COALESCE(SUM(m.monto) FILTER (WHERE m.origen_tipo <> 'cierre'), 0)                          AS saldo_final
  FROM movimientos m JOIN cuentas c ON c.id = m.cuenta_id AND c.tipo = 'jugador'
 GROUP BY m.tenant_id, c.jugador_id, m.temporada_id;

CREATE VIEW v_poder_apuesta WITH (security_invoker = true) AS
SELECT j.tenant_id, j.id AS jugador_id, j.tipo_cuenta, j.estatus,
       saldo_jugador(j.id)                                                       AS saldo,
       j.limite_credito,
       reservado_jugador(j.id)                                                   AS reservado,
       saldo_jugador(j.id) + j.limite_credito - reservado_jugador(j.id)          AS poder_apuesta,
       a_unidades(j.tenant_id, saldo_jugador(j.id) + j.limite_credito - reservado_jugador(j.id)) AS poder_apuesta_unidades
  FROM jugadores j;

-- =====================================================================
-- 16. SEGURIDAD MULTIEMPRESA (Row Level Security)
-- =====================================================================
DO $$
DECLARE t TEXT;
BEGIN
  FOR t IN
    SELECT c.table_name FROM information_schema.columns c
      JOIN information_schema.tables tb ON tb.table_schema = c.table_schema AND tb.table_name = c.table_name
     WHERE c.table_schema = 'public' AND c.column_name = 'tenant_id' AND tb.table_type = 'BASE TABLE'
  LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
    EXECUTE format($p$CREATE POLICY aislamiento_empresa ON %I
        USING      (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::bigint)
        WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::bigint)$p$, t);
  END LOOP;
END $$;

ALTER TABLE tenants ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenants FORCE ROW LEVEL SECURITY;
CREATE POLICY aislamiento_empresa ON tenants
  USING (id = NULLIF(current_setting('app.tenant_id', true), '')::bigint);

-- Rol del backend: NO usar superusuario ni el dueño de las tablas (se saltarían el RLS).
-- Descomenta y ajusta:
--   CREATE ROLE app_backend LOGIN PASSWORD 'cambiar';
--   GRANT USAGE ON SCHEMA public TO app_backend;
--   GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_backend;
--   GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO app_backend;
--   REVOKE UPDATE, DELETE ON movimientos, asientos FROM app_backend;
--   GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO app_backend;
-- Alta de empresas y login de usuarios (antes de conocer el tenant) se hacen con un rol
-- privilegiado aparte.

COMMIT;
