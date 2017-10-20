
CREATE EXTENSION IF NOT EXISTS fuzzystrmatch; -- for metaphone() and levenshtein()
CREATE EXTENSION IF NOT EXISTS unaccent; -- for unaccent()

DROP  SCHEMA lib CASCADE;
CREATE SCHEMA lib;


-- PUBLIC functions

-- -- -- -- -- --
-- Normalize and convert to integer-ranges, for postalCode_ranges.
-- See section "Preparation" at README.

CREATE or replace FUNCTION csvranges_to_int4ranges(
  p_range text
) RETURNS int4range[] AS $f$
   SELECT ('{'||
      regexp_replace( translate($1,' -',',') , '\[(\d+),(\d+)\]', '"[\1,\2]"', 'g')
   || '}')::int4range[];
$f$ LANGUAGE SQL IMMUTABLE;


CREATE or replace FUNCTION int4ranges_to_csvranges(
  p_range int4range[]
) RETURNS text AS $f$
   SELECT translate($1::text,',{}"',' ');
$f$ LANGUAGE SQL IMMUTABLE;


-- -- -- -- -- --
-- LIB and extras 
-- See https://github.com/datasets-br/diariosOficiais/blob/master/src/step1_strut.sql



CREATE FUNCTION lib.normalizeterm(
	--
	-- Converts string into standard sequence of lower-case words.
	--
	text,       		-- 1. input string (many words separed by spaces or punctuation)
	text DEFAULT ' ', 	-- 2. output separator
	int DEFAULT 320,	-- 3. max lenght of the result (system limit)
	p_sep2 text DEFAULT ' , ' -- 4. output separator between terms
) RETURNS text AS $f$
  SELECT  substring(
	LOWER(TRIM( regexp_replace(  -- for review: regex(regex()) for ` , , ` remove
		trim(regexp_replace($1,E'[\\n\\r \\+/,;:\\(\\)\\{\\}\\[\\]="\\s ]*[\\+/,;:\\(\\)\\{\\}\\[\\]="]+[\\+/,;:\\(\\)\\{\\}\\[\\]="\\s ]*|[\\s ]+[–\\-][\\s ]+',
				   p_sep2, 'g'),' ,'),   -- s*ps*|s-s
		E'[\\s ;\\|"]+[\\.\'][\\s ;\\|"]+|[\\s ;\\|"]+',    -- s.s|s
		$2,
		'g'
	), $2 )),
  1,$3
  );
$f$ LANGUAGE SQL IMMUTABLE;



CREATE FUNCTION lib.normalizeterm2(
	text,
	boolean DEFAULT true
) RETURNS text AS $f$
   SELECT (  lib.normalizeterm(
          CASE WHEN $2 THEN substring($1 from '^[^\(\)\/;]+' ) ELSE $1 END,
	  ' ',
	  320,
          ' / '
   ));
$f$ LANGUAGE SQL IMMUTABLE;


CREATE or replace FUNCTION lib.name2lex(
  p_name text,
  p_normalize boolean DEFAULT true,
  p_cut boolean DEFAULT true
) RETURNS text AS $f$
   SELECT unaccent(trim(replace(
	   regexp_replace(
	     CASE WHEN p_normalize THEN lib.normalizeterm2($1,p_cut) ELSE $1 END,
	     E' d[aeo] | d[oa]s | com | para |^d[aeo] | / .+| [aeo]s | [aeo] |[\-\' ]',
	     '.',
	     'g'
	   ),
	   '..',
           '.'
       ),'.'))
$f$ LANGUAGE SQL IMMUTABLE;


/**
 * Base36 integer conversion.
 * @see https://gist.github.com/btbytes/7159902
 */
CREATE or replace FUNCTION base36_encode(IN digits bigint, IN min_width int = 0) RETURNS varchar AS $$
DECLARE
    chars char[]; 
    ret varchar; 
    val bigint; 
BEGIN
    chars := array['0','1','2','3','4','5','6','7','8','9',
      'a','b','c','d','e','f','g','h','i','j','k','l','m','n','o','p','q','r','s','t','u','v','w','x','y','z'  
    ];
    val := digits; 
    ret := ''; 
    IF val < 0 THEN 
        val := val * -1; 
    END IF; 
    WHILE val != 0 LOOP 
        ret := chars[(val % 36)+1] || ret; 
        val := val / 36; 
    END LOOP;

    IF min_width > 0 AND char_length(ret) < min_width THEN 
        ret := lpad(ret, min_width, '0'); 
    END IF;

    RETURN ret;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE or replace FUNCTION lib.br_city_id_gap(text) RETURNS int AS $f$
-- Gap maximo de 10 conforme convenção códigos IBGE. Avaliação de balanço inspirada pela raiz quadrada:
-- SELECT json_build_object(i,s) from (select substr(unaccent(name),1,1) as i, count(*) as n, sqrt(count(*))::int as s 
--    from tmpcsv_cities_wiki group by 1 order by 2 desc) t;

	SELECT CASE WHEN jgap->ini IS NULL THEN 3 ELSE (jgap->>ini)::int END 
	FROM  
	(SELECT upper(substr(unaccent($1),1,1)) as ini) t1,
	(SELECT '{"S":10,"C":10,"P":9,"A":8,"M":8,"I":8,"B":8,"T":6,"J":6,"R":6,"N":6,"G":6,"L":6,"F":4,"V":4,"D":4,"E":4,"O":4,"U":4}'::JSON as jgap) t2;
$f$ LANGUAGE SQL IMMUTABLE;
