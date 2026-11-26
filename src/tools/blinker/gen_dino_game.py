#!/usr/bin/env python3
# Copyright 2026 The Chromium Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
"""Збирає гру з динозавром для сторінки помилки в content/shell/common/blinker_dino_game.h.

Код гри це компільований components/neterror/resources/dino_game з тієї
збірки, де його вже скомпілювали. Rollup і terser лежать у third_party/node.
Запуск з кореня src:

  python3 tools/blinker/gen_dino_game.py out/blink15
"""

import base64
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
NODE = os.path.join(ROOT, 'third_party', 'node', 'mac', 'node-darwin-x64',
                    'bin', 'node')
OFFLINE_IMAGES = os.path.join(ROOT, 'components', 'neterror', 'resources',
                              'images')
OUTPUT = os.path.join(ROOT, 'content', 'shell', 'common',
                      'blinker_dino_game.h')

ROLLUP_RUNNER = r'''
import {createRequire} from 'node:module';
const {rollup} = createRequire(import.meta.url)('%(rollup)s');
const bundle = await rollup({
  input: '%(entry)s',
  plugins: [{
    name: 'webui-resources',
    resolveId(id) {
      const prefix = 'chrome://resources/';
      return id.startsWith(prefix) ? '%(resources)s' + id.slice(prefix.length)
                                   : null;
    },
  }],
});
const {output} = await bundle.generate({format: 'iife'});
process.stdout.write(output[0].code);
'''


def data_uri(path):
  with open(path, 'rb') as f:
    return 'data:image/png;base64,' + base64.b64encode(f.read()).decode()


def main():
  build = os.path.join(ROOT, sys.argv[1] if len(sys.argv) > 1 else 'out/blink15')
  neterror = os.path.join(build, 'gen', 'components', 'neterror', 'resources',
                          'tsc')
  resources = os.path.join(build, 'gen', 'ui', 'webui', 'resources', 'tsc',
                           '')
  rollup = os.path.join(ROOT, 'third_party', 'node', 'node_modules', '@rollup',
                        'wasm-node', 'dist', 'rollup.js')
  with tempfile.TemporaryDirectory() as work:
    entry = os.path.join(work, 'entry.mjs')
    with open(entry, 'w') as f:
      f.write(
          "import {loadTimeData} from 'chrome://resources/js/load_time_data.js';\n"
          "import {Runner} from '%s/dino_game/offline.js';\n"
          "loadTimeData.data = {};\n"
          "window.blinkerDino = Runner.initializeInstance('.interstitial-wrapper');\n"
          % neterror)
    runner = os.path.join(work, 'run.mjs')
    with open(runner, 'w') as f:
      f.write(ROLLUP_RUNNER % {'rollup': rollup, 'entry': entry,
                               'resources': resources})
    bundled = subprocess.run([NODE, runner], check=True, capture_output=True,
                             text=True).stdout

  # Гра на iOS без звуку і з дотиками, тож ознаки платформи задані прямо.
  bundled, ios = re.subn(r'const IS_IOS = /CriOS/\.test\(window\.navigator\.userAgent\);',
                         'const IS_IOS = true;', bundled)
  bundled, mobile = re.subn(
      r'const IS_MOBILE = /Android/\.test\(window\.navigator\.userAgent\) \|\| IS_IOS;',
      'const IS_MOBILE = true;', bundled)
  if ios != 1 or mobile != 1:
    sys.exit('Не знайшов ознаки платформи в зібраній грі, змінився код.')

  with tempfile.NamedTemporaryFile('w', suffix='.js', delete=False) as f:
    f.write(bundled)
    path = f.name
  terser = os.path.join(ROOT, 'third_party', 'node', 'node_modules', 'terser',
                        'bin', 'terser')
  minified = subprocess.run([NODE, terser, path, '--compress', '--mangle'],
                            check=True, capture_output=True, text=True).stdout
  os.unlink(path)
  if ')JS"' in minified:
    sys.exit('Код гри містить роздільник рядка.')

  sprite_1x = data_uri(os.path.join(OFFLINE_IMAGES, 'default_100_percent',
                                    'offline', '100-offline-sprite.png'))
  sprite_2x = data_uri(os.path.join(OFFLINE_IMAGES, 'default_200_percent',
                                    'offline', '200-offline-sprite.png'))
  with open(OUTPUT, 'w') as out:
    out.write('''// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Створено tools/blinker/gen_dino_game.py, руками не міняти.

#ifndef CONTENT_SHELL_COMMON_BLINKER_DINO_GAME_H_
#define CONTENT_SHELL_COMMON_BLINKER_DINO_GAME_H_

namespace content {

inline constexpr char kBlinkerDinoSprite1x[] =
    "%s";

inline constexpr char kBlinkerDinoSprite2x[] =
    "%s";

inline constexpr char kBlinkerDinoScript[] = R"JS(%s)JS";

}  // namespace content

#endif  // CONTENT_SHELL_COMMON_BLINKER_DINO_GAME_H_
''' % (sprite_1x, sprite_2x, minified))
  print('Записано %s, гра %d байт' % (OUTPUT, len(minified)))


if __name__ == '__main__':
  main()
