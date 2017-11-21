DROP SCHEMA IF EXISTS dataset CASCADE; -- danger when reusing

CREATE SCHEMA dataset;

-- -- -- --
-- VALIDATION-CHECK functions
CREATE FUNCTION dataset.makekx_urn(p_name text,p_namespace text DEFAULT '') RETURNS text AS $f$
	SELECT CASE
		WHEN $2='' OR $2 IS NULL THEN $1
		ELSE lower($2)||':'||$1
	END
$f$ LANGUAGE SQL IMMUTABLE;

CREATE FUNCTION dataset.makekx_uname(p_uname text) RETURNS text AS $f$
	SELECT  lower(lib.normalizeterm($1))
$f$ LANGUAGE SQL IMMUTABLE;

-- -- -- --
-- -- Tables

CREATE TABLE dataset.ns(
  -- Namespace
  ns_id  int NOT NULL PRIMARY KEY, -- not serial, see trigger
  name text NOT NULL,  -- namespace label
  dft_lang text,  -- default lang of datasets
  info JSONb,    -- any metadata as description, etc.
  created date DEFAULT now(),
  UNIQUE(name)
);
INSERT INTO dataset.ns (name,ns_id) VALUES ('',0); -- the default namespace!

CREATE TABLE dataset.jtd (
  -- JSON Type Definition
  jtd_id  serial NOT NULL PRIMARY KEY,
  name text NOT NULL,  -- JTD label (json-schema URN)
	description text NOT NULL,  -- human-readable
  info JSONb,    -- any metadata as description, etc.
  created date DEFAULT now(),
  UNIQUE(name)
);
INSERT INTO dataset.jtd (name,description,info) VALUES  -- main and examples
	('tab-aoa','JSON Tabular Array of Array-rows, one SQL field with all rows. Separated header. Best.','{"about":"http://frictionlessdata.io/specs/tabular-data-resource/#json-tabular-data"}'::jsonb)
	,('tab-1apr','Tabular, distributed in many SQL rows, one JSON-array per SQL-row.',NULL::jsonb)
	,('objs-free','Objects, free-structure, all dataset in only one JSON set of objects. Non tabular (ex. free taxonomy)',NULL::jsonb)
	,('json-ld','','{"about":""}'::jsonb)
	,('tab-aoo','JSON Tabular Array of Object-rows, one SQL field with all rows. Please avoid! prefer tab-aoa.','{"about":"http://frictionlessdata.io/specs/tabular-data-resource/#json-tabular-data"}'::jsonb)
	,('tab-1opr','Tabular, distributed in many SQL rows, each row with an Object. Please avoid! prefer tab-1apr.',NULL::jsonb)
	,('tab-aoa-trans1','A tab-aoa with Transactional-expenditure-data-v1 (see URL) semantics and its minimal structure.','{"about":"http://frictionlessdata.io/specs/fiscal-data-package/#transactional-expenditure-data"}'::jsonb)
;  -- see also export_thing formats
   -- see also Assert specification at https://docs.google.com/spreadsheets/d/1c-Te6jbteKkXBlaL8ceeQMzLtta-cAXLOwet4VnjCoc/

-- DROP TABLE IF EXISTS dataset.meta CASCADE;
CREATE TABLE dataset.meta (
	id serial PRIMARY KEY,
	namespace text NOT NULL DEFAULT '' REFERENCES dataset.ns(name),
	name text NOT NULL, -- original dataset name or filename of the CSV
	jtd text NOT NULL DEFAULT 'tab-aoa' REFERENCES dataset.jtd(name), -- JSON Schema
	is_canonic BOOLEAN DEFAULT false, -- for canonic or "reference datasets". Curated by community.
	sametypes_as text,  -- kx_urn of an is_canonic-dataset with same kx_types. For merge() or UNION.
	projection_of text, -- kx_urn of its is_canonic-dataset, need to map same kx_types. No canonic is a projection.
	info JSONb, -- all metadata (information) here!
  asserts text, -- an SQL script?
	created date DEFAULT now(),
	-- Cache fields generated by UPDATE or trigger.
	kx_uname text, -- the normalized name, used for  dataset.meta_id() and SQL-View labels
	kx_urn text,   -- the transparent ID for this dataset.  "$namespace:$kx_uname".
	kx_fields text[], -- field names as in info.
	kx_types text[],  -- field JSON-datatypes as in info.
  kx_asserts_report text

	,UNIQUE(namespace,kx_uname) -- not need but same as kx_urn
	,CHECK( lib.normalizeterm(namespace)=namespace AND lower(namespace)=namespace )
	,CHECK( kx_uname=dataset.makekx_uname(name) )
	--,CHECK( kx_urn=dataset.makekx_urn(kx_urn,namespace) )
	--,CHECK( NOT(is_canonic) OR (is_canonic AND projection_of IS NULL) )
);

CREATE TABLE dataset.big (
  id bigserial not null primary key,
  source int NOT NULL REFERENCES dataset.meta(id) ON DELETE CASCADE, -- Dataset ID and metadata.
	is_distrib boolean NOT NULL DEFAULT false, -- distributing same source in many JSONs
  j JSONb NOT NULL
);

-- -- --
-- -- --
-- Essential functions

CREATE FUNCTION dataset.meta_id(text,text DEFAULT NULL) RETURNS int AS $f$
	SELECT id
	FROM dataset.meta
	WHERE (CASE WHEN $2 IS NULL THEN kx_urn=$1 ELSE kx_uname=$1 AND namespace=$2 END)
$f$ LANGUAGE SQL IMMUTABLE;

CREATE FUNCTION dataset.ns_id(text) RETURNS int AS $f$
	SELECT ns_id FROM dataset.ns WHERE name=$1
$f$ LANGUAGE SQL IMMUTABLE;

CREATE or replace FUNCTION dataset.viewname(p_dataset_id int, istab boolean=false) RETURNS text AS $f$
  SELECT CASE WHEN $2 THEN 'tmpcsv' ELSE 'vw' END
	  || CASE WHEN m.namespace!='' THEN dataset.ns_id(m.namespace)::text ELSE '' END
		||'_'|| m.kx_uname
	FROM dataset.meta m
	WHERE m.id=$1
$f$ language SQL IMMUTABLE;

CREATE or replace FUNCTION dataset.viewname(text,text DEFAULT NULL,boolean DEFAULT false) RETURNS text AS $f$
	SELECT dataset.viewname(id,$3)
	FROM dataset.meta
	WHERE (CASE WHEN $2 IS NULL THEN kx_urn=$1 ELSE kx_uname=$1 AND namespace=$2 END)
$f$ LANGUAGE SQL IMMUTABLE;

CREATE or replace FUNCTION dataset.meta_refresh() RETURNS TRIGGER AS $f$
BEGIN
	IF NOT EXISTS (SELECT 1 FROM dataset.ns WHERE name = NEW.namespace) THEN
		-- RAISE NOTICE '-- DEBUG02 see NS %', NEW.namespace;
		INSERT INTO dataset.ns (name,ns_id) VALUES ( -- future = use trigger
			NEW.namespace,
			lib.hash_digits_addnew( NEW.namespace, (select array_agg(ns_id) from dataset.ns) )
		);
	END IF; -- future = controlling here the namespaces and kx_ns.
	NEW.kx_uname := dataset.makekx_uname(NEW.name);
	NEW.kx_urn   := dataset.makekx_urn(NEW.kx_uname,NEW.namespace);
	IF NEW.info IS NOT NULL THEN
	 	NEW.kx_fields := dataset.metaget_schema_field(NEW.info,'name');
		NEW.kx_types  := dataset.metaget_schema_field(NEW.info,'type');
	END IF;
	RETURN NEW;
END;
$f$ LANGUAGE plpgsql;



/**
 * Get primary-keys from standard JSON package.
 * @return array with each key.
 */
CREATE or replace FUNCTION dataset.jget_pks(JSONb) RETURNS text[] AS $f$
  SELECT  array_agg(k::text)
  FROM (
    SELECT  jsonb_array_elements( CASE
      WHEN $1->>'primaryKey' IS NULL THEN to_jsonb(array[]::text[])
      WHEN jsonb_typeof($1->'primaryKey')='string' THEN to_jsonb(array[$1->'primaryKey'])
      ELSE $1->'primaryKey'
    END )#>>'{}' as k
  ) t
$f$ language SQL IMMUTABLE;

-- -- --
-- -- --
-- Triggers
CREATE TRIGGER dataset_meta_kx  BEFORE INSERT OR UPDATE
    ON dataset.meta
		FOR EACH ROW EXECUTE PROCEDURE dataset.meta_refresh()
;

-- -- --
-- -- --
-- VIEWS
-- (name convention: "vw_" prefix for dataset-view, "v" prefix for main structure)

CREATE VIEW dataset.big_full AS
  SELECT m.*, b.is_distrib, b.id as part_id, b.j, n.ns_id, j.jtd_id
  FROM dataset.big b INNER JOIN dataset.meta m ON b.source=m.id
      INNER JOIN dataset.jtd j ON j.name=m.jtd
			INNER JOIN dataset.ns n  ON m.namespace=n.name
;

CREATE VIEW dataset.vmeta_summary_aux AS
  SELECT m.id, '('|| dataset.ns_id(m.namespace)||')'|| m.kx_urn as urn,  array_to_string(dataset.jget_pks(m.info),'/') as pkey,
	  m.info->>'lang' as lang,  m.jtd,
    jsonb_array_length(m.info#>'{schema,fields}') as n_cols, t.n_rows
    -- jsonb_pretty(info) as show_info
  FROM dataset.meta m,
	     LATERAL  (SELECT sum(jsonb_array_length(j)) as n_rows FROM dataset.big WHERE source=m.id AND m.jtd IN ('tab-aoa','tab-aoo')) t
	ORDER BY 2
;
CREATE VIEW dataset.vmeta_summary AS
  SELECT id, urn, pkey::text, jtd, n_cols, n_rows
	FROM dataset.vmeta_summary_aux
;
CREATE VIEW dataset.vjmeta_summary AS
  SELECT jsonb_agg(to_jsonb(v)) AS jmeta_summary
	FROM dataset.vmeta_summary_aux v
;

CREATE VIEW dataset.vmeta_fields AS
  SELECT id, urn, f->>'name' as field_name, f->>'type' as field_type,
         f->>'description' as field_desc
  FROM (
    SELECT id, kx_urn as urn, jsonb_array_elements(info#>'{schema,fields}') as f
    FROM dataset.meta
  ) t
;
CREATE VIEW dataset.vjmeta_fields AS
  -- use SELECT jsonb_agg(jmeta_fields) as j FROM dataset.vjmeta_fields WHERE dataset_id IN (1,3);
	SELECT id AS dataset_id,
	  jsonb_build_object('dataset', dataset, 'fields', json_agg(field)) AS jmeta_fields
	FROM (
	  SELECT id,
		     jsonb_build_object('id',id, 'urn',urn) as dataset,
	       jsonb_build_object('field_name',field_name, 'field_type',field_type, 'field_desc',field_desc) as field
	  FROM dataset.vmeta_fields
	) t
	GROUP BY id, dataset
;


---------------------------------------




-- -- --
-- -- --
-- JSONb toolkit.  See framework.... Move to there?

-- need review for JTD.
CREATE FUNCTION dataset.jsonb_arrays(int) RETURNS JSONb AS $f$
	SELECT jsonb_agg(x) FROM (
			SELECT to_jsonb(kx_fields) FROM dataset.meta WHERE id=$1
			UNION ALL
			(SELECT j FROM dataset.big WHERE source=$1)
		) t(x)
$f$ language SQL IMMUTABLE;

CREATE FUNCTION dataset.jsonb_arrays(text, text default NULL) RETURNS JSONb AS $wrap$
  SELECT dataset.jsonb_arrays( dataset.meta_id($1,$2) )
$wrap$ language SQL IMMUTABLE;


CREATE FUNCTION dataset.jsonb_objects(int) RETURNS JSONb AS $f$
	SELECT jsonb_agg(jsonb_object(k,x))
	FROM
		(SELECT jsonb_array_totext(j) FROM dataset.big WHERE source=$1) b(x), -- ugly convertion, lost JSON datatype
		(SELECT kx_fields FROM dataset.meta WHERE id=$1) t(k)
$f$ language SQL IMMUTABLE;

CREATE FUNCTION dataset.jsonb_objects(text, text default NULL) RETURNS JSONb AS $wrap$
  SELECT dataset.jsonb_objects( dataset.meta_id($1,$2) )
$wrap$ language SQL IMMUTABLE;


-- definir função que explode um big-full nas suas partes, e sem tanto meta.
-- big as JSON-TABLE. ... Depois as JSON-dataset.

/**
 * get from dataset.big the raw-JSON as JDT
 */
CREATE FUNCTION dataset.big_asrows_aoa(p_id integer) RETURNS SETOF JSONb AS $f$
  SELECT CASE
		WHEN jtd='tab-aoa' THEN jsonb_array_elements(j)
		ELSE ('{"ERROR":"JTD '|| jtd ||' IS UNKNOWN OR UNDER CONSTRUCTION."}')::JSONb
		END j
	FROM dataset.big_full WHERE id=$1
$f$ language SQL IMMUTABLE;

CREATE FUNCTION dataset.big_asrows_aoa(text) RETURNS SETOF JSONb AS $wrap$
  SELECT dataset.big_asrows_aoa( dataset.meta_id($1) )
$wrap$ language SQL IMMUTABLE;

/**
 * Same as dataset.big_asrows_aoa(), adding a header.
 */
CREATE or replace FUNCTION dataset.big_asrows_aoa_head(p_id integer) RETURNS TABLE (j JSONb) AS $f$
	-- add source_id, row_id
	SELECT to_jsonb(kx_fields) FROM dataset.meta WHERE id=$1
	UNION ALL
  (SELECT x FROM dataset.big_asrows_aoa($1) t(x))
$f$ language SQL IMMUTABLE;

CREATE FUNCTION dataset.big_asrows_aoa_head(text) RETURNS TABLE (j JSONb) AS $wrap$
  SELECT dataset.big_asrows_aoa_head( dataset.meta_id($1) )
$wrap$ language SQL IMMUTABLE;
