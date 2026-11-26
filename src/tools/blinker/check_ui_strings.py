#!/usr/bin/env python3
# Copyright 2026 The Chromium Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
"""Перевіряє content/shell/app/ios/resources/ui_strings.json.

Кожен англійський рядок має мати переклад усіма мовами, з тими самими
специфікаторами формату і тією ж кількістю переносів рядка.
"""

import json
import os
import re
import sys

LANGS = ['ar', 'cs', 'de', 'es', 'fr', 'ja', 'ko', 'pl', 'ru', 'sv', 'tr', 'uk',
         'vi', 'zh']
SPEC = re.compile(r'%(?:%|@|l{0,2}[du]|zu)')
# В інтерфейсі їх нема навмисно, текст ділять коми і крапки. Дефіс теж,
# замість нього пробіл.
BANNED = ['·', '—', '–', '|', ' / ', '•', ';', '；',
          '؛', '-']


def main():
  root = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')
  path = os.path.join(root, 'content', 'shell', 'app', 'ios', 'resources',
                      'ui_strings.json')
  with open(path, encoding='utf-8') as f:
    strings = json.load(f)
  problems = []
  for english, translations in strings.items():
    if sorted(translations) != LANGS:
      problems.append(f'{english!r} мови {sorted(translations)}')
      continue
    for lang, text in translations.items():
      where = f'{english!r} [{lang}]'
      if not text.strip():
        problems.append(f'{where} порожній')
      if sorted(SPEC.findall(english)) != sorted(SPEC.findall(text)):
        problems.append(f'{where} інші специфікатори формату')
      if english.count('\n') != text.count('\n'):
        problems.append(f'{where} інша кількість переносів')
      for mark in BANNED:
        if mark in text and mark not in english:
          problems.append(f'{where} зайвий знак {mark!r}')
  for line in problems:
    print(line)
  print(f'{len(strings)} рядків, {len(LANGS)} мов, проблем {len(problems)}')
  return 1 if problems else 0


if __name__ == '__main__':
  sys.exit(main())
