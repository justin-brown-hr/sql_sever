using Microsoft.SqlServer.TransactSql.ScriptDom;
using System.Text.RegularExpressions;

// Syntax validation only: a parser cannot bind names to the client's database,
// execute triggers, validate data-dependent conversions, or prove rollback.
var parser = new TSql150Parser(initialQuotedIdentifiers: true);
int failures = 0, files = 0, dynamicBatches = 0;
var execLiteral = new Regex(@"\bEXEC(?:UTE)?\s+sys\.sp_executesql\s+N?'((?:[^']|'')*)'",
    RegexOptions.IgnoreCase);
foreach (string path in args)
{
    string source = File.ReadAllText(path);
    Check(source, path);
    foreach (Match m in execLiteral.Matches(source))
    {
        int line = source[..m.Index].Count(c => c == '\n') + 1;
        Check(m.Groups[1].Value.Replace("''", "'"), $"{path}:dynamic SQL at line {line}");
        dynamicBatches++;
    }
    files++;
}
if (files == 0) throw new ArgumentException("Pass SQL file paths to validate.");
Console.WriteLine($"{(failures == 0 ? "PASS" : "FAIL")}: Microsoft ScriptDom SQL Server 2019 grammar: {files} files, {dynamicBatches} literal dynamic batches, {failures} errors");
return failures == 0 ? 0 : 1;

void Check(string sql, string label)
{
    parser.Parse(new StringReader(sql), out var errors);
    foreach (var error in errors)
    {
        Console.WriteLine($"{label}:{error.Line}:{error.Column}: SQL{error.Number}: {error.Message}");
        failures++;
    }
}
