using Microsoft.SqlServer.TransactSql.ScriptDom;
using System.Text.Json;

// Binding/coverage checks against the reference DDL, not a client SQL Server run.
static class AuditCoverage
{
    static readonly HashSet<string> Tables = new(StringComparer.OrdinalIgnoreCase) {
        "UPR","ADDRESS","COMPLEX","PROPERTY","CONDO","BUILDING","UNIT","CONTACT",
        "UPR_ADDRESS","UPR_CONTACT","EXTERNAL_IDENTIFIER_XREF","UPR_CLOSURE",
        "UPRMATCHREVIEW_Q","UPRSTATUSHISTORY","REF_ENTITYTYPE","REF_PROPERTYTYPE",
        "REF_ROLETYPE","REF_ADDRESSROLE","REF_CONTACTTYPE" };
    static TSqlFragment Parse(string path) {
        var tree=new TSql150Parser(true).Parse(new StringReader(File.ReadAllText(path)),out var errors);
        if(errors.Count!=0)throw new Exception($"Syntax errors in {path}"); return tree;
    }
    public static int Run(string loader,string ddl,string? baseline,string? export) {
        var schema=new Schema();Parse(ddl).Accept(schema);
        var now=new Writes();Parse(loader).Accept(now);
        var gen=new Sql150ScriptGenerator();
        var signatures=new List<string>(); var expressions=new List<object>();
        foreach(var (table,spec) in now.Items) {
            var output=spec.OutputIntoClause ?? throw new Exception($"Missing audit OUTPUT: {table} line {spec.StartLine}");
            if(output.SelectColumns.Count!=output.IntoTableColumns.Count)throw new Exception($"OUTPUT arity: {table}");
            var target=((NamedTableReference)output.IntoTable).SchemaObject.BaseIdentifier.Value;
            if(target!="#AuditEvents" && !output.IntoTableColumns.Any(c=>c.MultiPartIdentifier.Identifiers.Last().Value=="AuditNewValue"))
                throw new Exception($"MERGE missing audit image: {table}");
            var refs=new Columns();output.Accept(refs);
            foreach(var column in refs.Refs.Where(c=>c.MultiPartIdentifier?.Identifiers.Count==2)) {
                var ids=column.MultiPartIdentifier.Identifiers;
                if((ids[0].Value=="inserted"||ids[0].Value=="deleted") && !schema.Columns[table].Contains(ids[1].Value))
                    throw new Exception($"Audit output binds missing {table}.{ids[1].Value}");
            }
            var sql=new List<string>(); foreach(var col in output.SelectColumns){gen.GenerateScript(col,out var text);sql.Add(text);}
            expressions.Add(new {table,target,columns=sql});
            spec.OutputIntoClause=null; gen.GenerateScript(spec,out var signature);signatures.Add(signature);
        }
        if(now.Items.Select(x=>x.Table).Distinct(StringComparer.OrdinalIgnoreCase).Count()!=Tables.Count)
            throw new Exception("Not all loader tables covered");
        if(baseline!=null){
            var old=new Writes();Parse(baseline).Accept(old);
            var before=new List<string>();foreach(var (_,spec) in old.Items){spec.OutputIntoClause=null;gen.GenerateScript(spec,out var text);before.Add(text);}
            if(!before.SequenceEqual(signatures))throw new Exception("Business DML differs from baseline after removing audit OUTPUT");
        }
        if(export!=null)File.WriteAllText(export,JsonSerializer.Serialize(expressions));
        Console.WriteLine($"PASS: {now.Items.Count} business DML statements across {Tables.Count} tables have bound audit capture; OUTPUT arities match"+
            (baseline!=null?"; business DML unchanged from baseline":""));return 0;
    }
    class Schema:TSqlFragmentVisitor {
        public Dictionary<string,HashSet<string>> Columns=new(StringComparer.OrdinalIgnoreCase);
        public override void ExplicitVisit(CreateTableStatement n) {
            Columns[n.SchemaObjectName.BaseIdentifier.Value]=new(n.Definition.ColumnDefinitions.Select(x=>x.ColumnIdentifier.Value),StringComparer.OrdinalIgnoreCase);
            base.ExplicitVisit(n);
        }
    }
    class Names:TSqlFragmentVisitor {
        public List<NamedTableReference> Items=new();
        public override void ExplicitVisit(NamedTableReference n){Items.Add(n);base.ExplicitVisit(n);}
    }
    class Columns:TSqlFragmentVisitor {
        public List<ColumnReferenceExpression> Refs=new();
        public override void ExplicitVisit(ColumnReferenceExpression n){Refs.Add(n);base.ExplicitVisit(n);}
    }
    class Writes:TSqlFragmentVisitor {
        public List<(string Table,DataModificationSpecification Spec)> Items=new();
        string? Resolve(TableReference t,FromClause? from){
            if(t is not NamedTableReference n)return null;
            if(n.SchemaObject.SchemaIdentifier?.Value=="dbo")return n.SchemaObject.BaseIdentifier.Value;
            if(from==null)return null;var names=new Names();from.Accept(names);
            return names.Items.FirstOrDefault(x=>x.Alias?.Value==n.SchemaObject.BaseIdentifier.Value)?.SchemaObject.BaseIdentifier.Value;
        }
        void Add(DataModificationSpecification s,FromClause? from){var table=Resolve(s.Target,from);if(table!=null&&Tables.Contains(table))Items.Add((table,s));}
        public override void ExplicitVisit(InsertStatement n){Add(n.InsertSpecification,null);base.ExplicitVisit(n);}
        public override void ExplicitVisit(UpdateStatement n){Add(n.UpdateSpecification,n.UpdateSpecification.FromClause);base.ExplicitVisit(n);}
        public override void ExplicitVisit(DeleteStatement n){Add(n.DeleteSpecification,n.DeleteSpecification.FromClause);base.ExplicitVisit(n);}
        public override void ExplicitVisit(MergeStatement n){Add(n.MergeSpecification,null);base.ExplicitVisit(n);}
    }
}
