#!/usr/bin/env python3
# Copyright 2026 The Chromium Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
"""Будує blinker_extension_api_tables.h зі схем і можливостей API розширень.

Таблиця каже, які простори імен, функції, події, налаштування й переліки є в
Chrome на десктопі для звичайного розширення в стабільному каналі, і за якою
умовою з маніфесту. Шім доповнює нею те, що Blinker не реалізує, тож код
розширення бачить ту саму форму chrome.*, що в Chrome.

  tools/blinker/gen_extension_api_tables.py
"""

import argparse
import json
import os
import re

REPO = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))))
OUTPUT = os.path.join(REPO, 'content', 'shell', 'browser',
                      'blinker_extension_api_tables.h')
API_DIRS = ('chrome/common/extensions/api', 'extensions/common/api')
# runtime.getPlatformInfo у Blinker каже mac, тож поверхня як у Chrome для mac.
DESKTOP = {'mac'}
# Внутрішні простори Blinker не підміняє, а devtools.* живуть лише в
# сторінках інструментів розробника.
SKIP = ('test', 'devtools', 'experimental', 'mimeHandler')
# Значення, яке повертає get() налаштування, якого браузер не має. Для решти
# булевих це false, для переліків перше значення.
SETTING_DEFAULTS = {
    'privacy.websites.thirdPartyCookiesAllowed': True,
    'privacy.websites.referrersEnabled': True,
    'proxy.settings': {'mode': 'system'},
}


def loose_json(path):
  """JSON з коментарями і кінцевими комами, як у файлах схем Chromium."""
  text = open(path, encoding='utf-8').read()
  out, i, in_string = [], 0, False
  while i < len(text):
    ch = text[i]
    if in_string:
      out.append(ch)
      if ch == '\\':
        out.append(text[i + 1])
        i += 2
        continue
      if ch == '"':
        in_string = False
    elif ch == '"':
      in_string = True
      out.append(ch)
    elif text.startswith('//', i):
      while i < len(text) and text[i] != '\n':
        i += 1
      continue
    elif text.startswith('/*', i):
      i = text.index('*/', i) + 2
      continue
    else:
      out.append(ch)
    i += 1
  joined = re.sub(r',(\s*[}\]])', r'\1', ''.join(out)).strip()
  return json.loads(joined) if joined else {}


def load_features(src, kind):
  table = {}
  for d in API_DIRS:
    for suffix in ('.json', '.override.json'):
      path = os.path.join(src, d, f'_{kind}_features{suffix}')
      if os.path.exists(path):
        table.update(loose_json(path))
  return table


class Features:

  def __init__(self, src):
    self.api = load_features(src, 'api')
    self.permission = load_features(src, 'permission')
    self.manifest = load_features(src, 'manifest')

  def entries(self, table, name):
    """Записи можливості з успадкованими від батьківської полями."""
    value = table.get(name)
    if value is None:
      return None
    entries = value if isinstance(value, list) else [value]
    parent_name = name.rsplit('.', 1)[0] if '.' in name else None
    parent = self.entries(table, parent_name) if parent_name else None
    if not parent:
      return entries
    base = next((e for e in parent if e.get('default_parent')), parent[0])
    return [e if e.get('noparent') else {**base, **e} for e in entries]

  @staticmethod
  def versions(entry):
    low = entry.get('min_manifest_version', 2)
    high = entry.get('max_manifest_version', 3)
    return {v for v in (2, 3) if low <= v <= high}

  @staticmethod
  def plain(entry, context=None):
    """Чи може запис діяти для звичайного розширення зі стабільного каналу."""
    if entry.get('internal') or entry.get('allowlist'):
      return False
    if entry.get('location') or entry.get('feature_flag'):
      return False
    if entry.get('session_types'):
      return False
    if entry.get('channel', 'stable') != 'stable':
      return False
    platforms = entry.get('platforms')
    if platforms and not DESKTOP & set(platforms):
      return False
    types = entry.get('extension_types')
    if types and types != 'all' and 'extension' not in types:
      return False
    if context:
      contexts = entry.get('contexts', [])
      if contexts != 'all' and context not in contexts:
        return False
    return True

  def dependency(self, dep):
    """Версії маніфесту, за яких залежність виконується, або порожньо."""
    kind, _, name = dep.partition(':')
    if kind == 'api':
      # windows залежить від api:tabs, який сам нічого не вимагає.
      found = self.availability(name)
      if any(deps for deps, _, _ in found):
        raise ValueError(f'{dep} needs a requirement of its own')
      return set().union(*(versions for _, versions, _ in found))
    table = {'permission': self.permission, 'manifest': self.manifest}.get(kind)
    if table is None:
      return set()
    found = set()
    for entry in self.entries(table, name) or []:
      if self.plain(entry):
        found |= self.versions(entry)
    return found

  def availability(self, name):
    """[(вимога, версії, чи є у воркері)] для простору або його члена."""
    out = []
    for entry in self.entries(self.api, name) or []:
      if not self.plain(entry, 'privileged_extension'):
        continue
      versions = self.versions(entry)
      deps = entry.get('dependencies', [])
      for dep in deps:
        versions &= self.dependency(dep)
      if not versions:
        continue
      deps = [d for d in deps if not d.startswith('api:')]
      out.append(('&'.join(sorted(deps)), frozenset(versions),
                  not entry.get('disallow_for_service_workers')))
    return out


def snake(name):
  return re.sub(r'([a-z0-9])([A-Z])', r'\1_\2', name).replace('.', '_').lower()


class Schema:

  def __init__(self):
    self.functions = []
    self.events = []
    self.rule_events = []
    self.classes = []
    self.settings = []
    self.enums = {}
    self.consts = {}
    # Обмеження окремих членів зі схеми, а не з можливостей.
    self.member_platforms = {}
    self.member_versions = {}


def schema_versions(node):
  low = node.get('minManifestVersion', 2)
  high = node.get('maxManifestVersion', 3)
  return {v for v in (2, 3) if low <= v <= high}


def walk_settings(schema, namespace, properties, path):
  for key, prop in properties.items():
    full = f'{path}.{key}'
    if prop.get('platforms') and not DESKTOP & set(prop['platforms']):
      continue
    ref = prop.get('$ref', '')
    if ref in ('types.ChromeSetting', 'ContentSetting'):
      kind = 'chrome' if ref == 'types.ChromeSetting' else 'content'
      value = (prop.get('value') or [None, {}])[1]
      schema.settings.append((full, kind, value))
    elif prop.get('type') == 'object' and 'properties' in prop:
      walk_settings(schema, namespace, prop['properties'], full)
    elif 'value' in prop and not isinstance(prop['value'], (list, dict)):
      if path == namespace:
        schema.consts[key] = prop['value']


def parse_json(path, namespace):
  for space in loose_json(path):
    if space.get('namespace') != namespace:
      continue
    schema = Schema()
    for kind, items, out in (('f', space.get('functions', []),
                              schema.functions),
                             ('e', space.get('events', []), schema.events)):
      for item in items:
        name = item['name']
        if item.get('platforms'):
          schema.member_platforms[name] = set(item['platforms'])
        if 'maxManifestVersion' in item or 'minManifestVersion' in item:
          schema.member_versions[name] = schema_versions(item)
        if kind == 'e' and (item.get('options') or {}).get('supportsRules'):
          schema.rule_events.append(name)
        else:
          out.append(name)
    for t in space.get('types', []):
      tid = t['id'].split('.')[-1]
      if 'enum' in t:
        schema.enums[tid] = [e if isinstance(e, str) else e['name']
                             for e in t['enum']]
      instance = (t.get('properties') or {}).get('instanceType')
      if instance:
        schema.classes.append(tid)
    walk_settings(schema, namespace, space.get('properties', {}), namespace)
    return schema
  return None


def attributes(text):
  return dict((m.group(1), (m.group(2) or '').strip('"'))
              for m in re.finditer(r'(\w+)(?:=("[^"]*"|\([^)]*\)|[\w.]+))?',
                                   text or ''))


def member_rules(schema, name, attrs):
  if 'platforms' in attrs:
    schema.member_platforms[name] = set(re.findall(r'"(\w+)"',
                                                   attrs['platforms']))
  bounds = {}
  for key in ('maxManifestVersion', 'minManifestVersion'):
    if key in attrs:
      bounds[key] = int(attrs[key])
  if bounds:
    schema.member_versions[name] = schema_versions(bounds)


def parse_idl(path):
  text = re.sub(r'//[^\n]*', '', open(path, encoding='utf-8').read())
  schema = Schema()
  for m in re.finditer(r'\benum\s+(\w+)\s*\{(.*?)\}', text, re.S):
    body = re.sub(r'\[[^\]]*\]', '', m.group(2))
    values = [v.strip().strip('"') for v in body.split(',')]
    schema.enums[m.group(1)] = [v for v in values if v]
  for m in re.finditer(r'(\[[^\]]*\]\s*)?const\s+(long|double|DOMString|'
                       r'boolean)\s+(\w+)\s*=\s*([^;]+);', text):
    attrs, kind, name, value = (m.group(1) or '', m.group(2), m.group(3),
                                m.group(4).strip())
    string_value = re.search(r'StringValue="([^"]*)"', attrs)
    if kind == 'DOMString':
      schema.consts[name] = (string_value.group(1) if string_value
                             else value.strip('"'))
    elif kind == 'boolean':
      schema.consts[name] = value == 'true'
    else:
      schema.consts[name] = int(value) if kind == 'long' else float(value)
  member = (r'(?:\[([^\]]*)\]\s*)?static\s+(attribute\s+)?'
            r'((?:Promise<[^;]*?>|[\w<>?]+))\s+(\w+)\s*(\(|;)')
  if path.endswith('.webidl'):
    events = set(re.findall(r'interface\s+(\w+)\s*:\s*ExtensionEvent', text))
    for m in re.finditer(r'(partial\s+)?interface\s+(\w+)\s*(:\s*\w+)?\s*'
                         r'\{(.*?)\};', text, re.S):
      if m.group(1) or m.group(3):
        continue
      for f in re.finditer(member, m.group(4)):
        attrs, is_attribute, kind, name = (attributes(f.group(1)), f.group(2),
                                           f.group(3), f.group(4))
        if is_attribute:
          if kind in events:
            schema.events.append(name)
            member_rules(schema, name, attrs)
        else:
          schema.functions.append(name)
          member_rules(schema, name, attrs)
    return schema
  for block, out in (('Functions', schema.functions),
                     ('Events', schema.events)):
    m = re.search(r'interface\s+' + block + r'\s*\{(.*?)\};', text, re.S)
    if not m:
      continue
    for f in re.finditer(member, m.group(1)):
      out.append(f.group(4))
      member_rules(schema, f.group(4), attributes(f.group(1)))
  return schema


def read_schema(src, namespace):
  base = snake(namespace)
  for d in API_DIRS:
    for ext in ('.json', '.webidl', '.idl'):
      path = os.path.join(src, d, base + ext)
      if os.path.exists(path):
        return parse_json(path, namespace) if ext == '.json' else parse_idl(
            path)
  return None


def js_name(value):
  """Ключ переліку, як GetJSEnumEntryName у api_binding.cc."""
  if not value:
    return value
  out = '_' if value[0].isdigit() else ''
  for i, ch in enumerate(value):
    if i > 0 and value[i - 1].islower() and ch.isupper():
      out += '_' + ch
    elif ch == '-':
      out += '_'
    else:
      out += ch.upper()
  return out


def js_key(key):
  # Значення на зразок declarativeContent.PageStateMatcher дає ключ з крапкою.
  return key if re.fullmatch(r'[A-Za-z_$][\w$]*', key) else js_value(key)


def js_value(value):
  if isinstance(value, bool):
    return 'true' if value else 'false'
  if value is None:
    return 'null'
  if isinstance(value, str):
    return "'" + value.replace('\\', '\\\\').replace("'", "\\'") + "'"
  if isinstance(value, dict):
    return '{' + ','.join(f'{k}:{js_value(v)}' for k, v in value.items()) + '}'
  return str(value)


def setting_default(path, value_schema, schema):
  if path in SETTING_DEFAULTS:
    return SETTING_DEFAULTS[path]
  if value_schema.get('type') == 'boolean':
    return False
  values = value_schema.get('enum') or schema.enums.get(
      value_schema.get('$ref', ''))
  if values:
    first = values[0]
    return first if isinstance(first, str) else first['name']
  return {}


def flags(versions, worker):
  out = ''
  if versions == {2}:
    out += '2'
  elif versions == {3}:
    out += '3'
  if not worker:
    out += 'd'
  return out


def requirement(alternatives):
  """Залежності через пробіл, альтернативи через |."""
  return '|'.join(sorted({a.replace('&', ' ') for a in alternatives}))


def collect(src):
  features = Features(src)
  rows, settings, enums = [], [], []
  for name in sorted(features.api):
    if name.split('.')[0] in SKIP or name.startswith(SKIP):
      continue
    top = features.availability(name)
    if not top:
      continue
    # Член простору на зразок tabs.executeScript не має власної схеми.
    schema = read_schema(src, name)
    if schema is None:
      continue
    groups = {}
    members = ([('f', n) for n in schema.functions] +
               [('e', n) for n in schema.events] +
               [('r', n) for n in schema.rule_events] +
               [('c', n) for n in schema.classes])
    for kind, member in members:
      platforms = schema.member_platforms.get(member)
      if platforms and not DESKTOP & platforms:
        continue
      sub = (features.availability(f'{name}.{member}')
             if f'{name}.{member}' in features.api else top)
      for deps, versions, worker in sub:
        versions = versions & schema.member_versions.get(member, {2, 3})
        if not versions:
          continue
        lists = groups.setdefault((flags(versions, worker), deps), {
            'f': set(), 'e': set(), 'r': set(), 'c': set()})
        lists[kind].add(member)
    # Ті самі члени з різними вимогами стають одним рядком з альтернативами.
    merged = {}
    for (flag, deps), lists in groups.items():
      key = (flag,) + tuple(' '.join(sorted(lists[k])) for k in 'ferc')
      merged.setdefault(key, set()).add(deps)
    for key in sorted(merged):
      rows.append([name, requirement(merged[key])] + list(key))
    for path, kind, value in schema.settings:
      # Налаштування за прапорцем функції, як contentSettings.clipboard.
      parts = path.split('.')
      prefixes = ['.'.join(parts[:i]) for i in range(2, len(parts) + 1)]
      if any(p in features.api and not features.availability(p)
             for p in prefixes):
        continue
      settings.append([path, requirement(d for d, _, _ in top), kind,
                       setting_default(path, value, schema)
                       if kind == 'chrome' else None])
    items = []
    for tid in sorted(schema.enums):
      values = sorted(set(schema.enums[tid]))
      items.append(tid + ':{' + ','.join(js_key(js_name(v)) + ':' +
                                         js_value(v) for v in values) + '}')
    for const in sorted(schema.consts):
      items.append(const + ':' + js_value(schema.consts[const]))
    if items:
      enums.append((name, items))
  return rows, settings, enums


def js_rows(rows):
  return ','.join('[' + ','.join(js_value(v) for v in row) + ']'
                  for row in rows)


def cpp_literal(name, js):
  """Розбиває JS на рядки C++ не довші за 80 знаків."""
  lines, chunk = [], ''
  for ch in js:
    piece = ch.replace('\\', '\\\\').replace('"', '\\"')
    if len(chunk) + len(piece) > 74:
      lines.append(chunk)
      chunk = ''
    chunk += piece
  lines.append(chunk)
  body = '\n'.join(f'    "{line}"' for line in lines)
  return f'inline constexpr char {name}[] =\n{body};\n'


def main():
  parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
  parser.add_argument('--chromium-src', default=REPO)
  args = parser.parse_args()
  src = args.chromium_src
  version = dict(line.split('=', 1) for line in
                 open(os.path.join(src, 'chrome', 'VERSION')).read().split())
  version = '.'.join(version[k] for k in ('MAJOR', 'MINOR', 'BUILD', 'PATCH'))
  rows, settings, enums = collect(src)

  # Порожні хвости рядків не потрібні шіму.
  for row in rows:
    while row and row[-1] == '':
      row.pop()
  surface = ('const apiSurface=[' + js_rows(rows) + '];' +
             'const apiSettings=[' + js_rows(settings) + '];')
  types = ('const apiTypes={' +
           ','.join(f"'{ns}':{{{','.join(items)}}}" for ns, items in enums) +
           '};')
  guard = 'CONTENT_SHELL_BROWSER_BLINKER_EXTENSION_API_TABLES_H_'
  with open(OUTPUT, 'w', encoding='utf-8') as f:
    f.write(f"""// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Згенеровано tools/blinker/gen_extension_api_tables.py зі схем і можливостей
// API розширень Chromium {version}. Не редагуйте вручну.

#ifndef {guard}
#define {guard}

namespace content {{

// Рядок apiSurface це [простір, вимога, обмеження, функції, події, події з
// правилами, класи]. Вимога це залежності через пробіл, обмеження це 2 або 3
// для однієї версії маніфесту і d для члена, якого немає у воркері.
// apiSettings це [шлях, вимога, вид, значення].
{cpp_literal('kBlinkerApiSurfaceJs', surface)}
// Переліки й сталі просторів імен з іменами ключів як у GetJSEnumEntryName.
{cpp_literal('kBlinkerApiEnumsJs', types)}
}}  // namespace content

#endif  // {guard}
""")
  print(f'{len(rows)} rows, {len(settings)} settings, {len(enums)} '
        f'namespaces with enums -> {os.path.relpath(OUTPUT, REPO)}')


if __name__ == '__main__':
  main()
