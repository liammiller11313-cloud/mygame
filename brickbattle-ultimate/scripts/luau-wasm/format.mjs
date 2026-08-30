import { formatCode, Config, LuaVersion, IndentType, QuoteStyle,
         CollapseSimpleStatement, LineEndings, CallParenType,
         OutputVerification } from '@johnnymorganz/stylua';
import { readFileSync, writeFileSync } from 'node:fs';
function makeConfig() {
  const c = Config.new();
  c.syntax = LuaVersion.Luau; c.indent_type = IndentType.Tabs; c.indent_width = 4;
  c.column_width = 110; c.quote_style = QuoteStyle.AutoPreferDouble;
  c.call_parentheses = CallParenType.Always;
  c.collapse_simple_statement = CollapseSimpleStatement.Never;
  c.line_endings = LineEndings.Unix;
  return c;
}
let n = 0;
for (const f of process.argv.slice(2)) {
  const src = readFileSync(f, 'utf8');
  const out = formatCode(src, makeConfig(), undefined, OutputVerification.Full);
  if (out !== src) { writeFileSync(f, out); console.log(`  formatted ${f}`); n++; }
}
console.log(`${n} file(s) rewritten`);
