export function splitStatements(sql) {
  const cleaned = String(sql)
    .split('\n')
    .filter((line) => !line.trim().startsWith('--'))
    .join('\n');
  return cleaned
    .split(/;\s*\n/)
    .map((s) => s.trim())
    .filter((s) => s.length > 0 && !/^SET\s+NAMES/i.test(s));
}
