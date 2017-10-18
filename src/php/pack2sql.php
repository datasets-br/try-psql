<?php
/**
 * Interpreter for datapackage (of FrictionLessData.io standards) and script (SH and SQL) generator.
 * Generate scripts at ./cache.
 *
 * USE: php src/pack2sql.php
 *
 * USING generated scripts:
 *     sh src/cache/makeTmp.sh
 *     PGPASSWORD=postgres psql -h localhost -U postgres lexvoc < src/cache/makeTmp.sql
 *
 */


// CONFIGS:
$githubList = [
        'datasets/country-codes',
	'datasets-br/state-codes'=>'br-state-codes',
        'datasets-br/city-codes'
];
$useIDX = false;

// INITS:
$msg1 = "Script generated by datapackage.json files and pack2sql generator.";
$msg2 = "Created in ".substr(date("c", time()),0,10);
$IDX = 0;

$scriptSQL = "\n--\n-- $msg1\n-- $msg2\n--\n
	CREATE EXTENSION IF NOT EXISTS file_fdw;
	-- DROP SERVER IF EXISTS csv_files CASCADE; -- danger when using with other tools.
	CREATE SERVER csv_files FOREIGN DATA WRAPPER file_fdw;
";
$scriptSH  = "\n##\n## $msg1\n## $msg2\n##\n
	mkdir -p /tmp/tmpcsv
";

// MAIN:
fwrite(STDERR, "\n-------------\n BEGIN of cache-scripts generation\n");
fwrite(STDERR, "\n CONFIGS: useIDX=$useIDX, githubList=".count($githubList)." items.\n");

foreach($githubList as $prj=>$file) {
	if (ctype_digit((string) $prj)) list($prj,$file) = [$file,'_ALL_'];
	fwrite(STDERR, "\n Creating cache-scripts for $prj:");
	$urlBase = "https://raw.githubusercontent.com/$prj";
	$url = "$urlBase/master/datapackage.json";
	$pack = json_decode( file_get_contents($url), true );
	$test = [];
	$path = '';
	foreach ($pack['resources'] as $r) if ($file=='_ALL_' || $r['name']==$file) {
		$path = $r['path'];
		$IDX++;
		fwrite(STDERR, "\n\t Building table$IDX with $path.");
		list($file2,$sql) = addSQL($r,$IDX);
		$scriptSQL .= $sql;
		$url = "$urlBase/master/$path";
		$scriptSH  .= "\nwget -O $file2 -c $url";
	} else
		$test[] = $r['name'];
	if (!$path)
		fwrite(STDERR, "\n\t ERROR, no name corresponding to '$file': ".join(", ",$test)."\n");
}

$here = dirname(__FILE__); // local ./src/php
$cacheFolder = "$here/cache";  // realpath()
if (! file_exists($cacheFolder)) mkdir($cacheFolder);
file_put_contents("$cacheFolder/step1.sh", $scriptSH);
file_put_contents("$cacheFolder/step1.sql", $scriptSQL);

fwrite(STDERR, "\n END of cache-scripts generation\n See makeTmp.* scripts at $cacheFolder\n");


// // //
// LIB

function pg_varname($s) {
	return strtolower( str_replace('-','_',$s) );
}

function pg_defcol($f) { // define a table-column
	$pgconv = ['integer'=>'integer','boolean'=>'boolean','number'=>'numeric','float'=>'float'];
	$name  = pg_varname($f['name']);
	$jtype = strtolower($f['type']);
	$pgtype = isset($pgconv[$jtype])? $pgconv[$jtype]: 'text';
	return "$name $pgtype";
}

function addSQL($r,$idx) {
	global $useIDX;

	$p = $useIDX? "tmpcsc$idx": pg_varname( preg_replace('#^.+/|\.\w+$#','',$r['path']) );
	$table = $useIDX? $p: "tmpcsv_$p";
	$file = "/tmp/tmpcsv/$p.csv";

	$fields = [];
	foreach($r['schema']['fields'] as $f) $fields[]=pg_defcol($f);

	$sql = "
	  DROP FOREIGN TABLE IF EXISTS $table CASCADE; -- danger drop VIEWS
	  CREATE FOREIGN TABLE $table (\n\t\t". join(",\n\t\t",$fields) ."
	  ) SERVER csv_files OPTIONS ( 
	     filename '$file', 
	     format 'csv', 
	     header 'true'
	  );
	";
	return [$file,$sql];
}