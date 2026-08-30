// Syntax-check and format-check Luau with StyLua's WASM build.
// StyLua parses with full-moon, so a file that formats is a file that parses.
import { formatCode, Config, LuaVersion, IndentType, QuoteStyle,
         CollapseSimpleStatement, LineEndings, CallParenType,
         OutputVerification } from '@johnnymorganz/stylua';
import { readFileSync } from 'node:fs';

// formatCode takes OWNERSHIP of the Config and frees it, so a shared instance
// works exactly once and then hands back a dangling pointer. Build a fresh one
// per file. (Mirrors stylua.toml.)
function makeConfig() {
  const cfg = Config.new();
  cfg.syntax = LuaVersion.Luau;
  cfg.indent_type = IndentType.Tabs;
  cfg.indent_width = 4;
  cfg.column_width = 110;
  cfg.quote_style = QuoteStyle.AutoPreferDouble;
  cfg.call_parentheses = CallParenType.Always;
  cfg.collapse_simple_statement = CollapseSimpleStatement.Never;
  cfg.line_endings = LineEndings.Unix;
  return cfg;
}

let parseFails = 0, formatDiffs = 0, ok = 0;
for (const file of process.argv.slice(2)) {
  const src = readFileSync(file, 'utf8');
  let out;
  try {
    // Full verification re-parses the output and compares ASTs.
    out = formatCode(src, makeConfig(), undefined, OutputVerification.Full);
  } catch (e) {
    console.log(`PARSE FAIL  ${file}\n    ${String(e).split('\n').join('\n    ')}`);
    parseFails++;
    continue;
  }
  if (out !== src) {
    const a = src.split('\n'), b = out.split('\n');
    let n = 0;
    for (let i = 0; i < Math.max(a.length, b.length); i++) if (a[i] !== b[i]) n++;
    console.log(`FORMAT DIFF ${file}  (${n} line${n === 1 ? '' : 's'} differ)`);
    formatDiffs++;
  } else {
    ok++;
  }
}
console.log(`\n  ${ok} clean, ${formatDiffs} need formatting, ${parseFails} failed to parse`);
process.exit(parseFails > 0 ? 1 : 0);
