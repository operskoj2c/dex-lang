import sys
import os
from pathlib import Path
from itertools import product

RODINIA_ROOT = Path('rodinia')
if not RODINIA_ROOT.exists():
  print("Rodinia benchmark suite missing. Please download it and place it in a "
        "`rodinia/` subdirectory.")
  sys.exit(1)

EXE_ROOT = Path('exe')

# TODO: An easy way to do this would be to wrap the parameters in arrays, but
#       that doesn't work when the return type depends on any of them.
PREVENT_PARAMETER_INLINING = True
PRINT_OUTPUTS = False

def prepare_kmeans():
  kmeans_data_path = RODINIA_ROOT / 'data' / 'kmeans'
  kmeans_data_files = [
    (kmeans_data_path / '100', 10),
    (kmeans_data_path / '204800.txt', 8),
    (kmeans_data_path / 'kdd_cup', 5),
  ]

  kmeans_exe_path = EXE_ROOT / 'kmeans'
  kmeans_exe_path.mkdir(parents=True, exist_ok=True)

  for (df, k) in kmeans_data_files:
    with open(df, 'r') as f:
      lines = [l for l in f.read().split('\n') if l]
      vals = [map(ensure_float, l.split()[1:]) for l in lines]
    case_exe_path = kmeans_exe_path / (df.stem + '.dx')
    with open(case_exe_path, 'w') as f:
      emit_dex(f, 'kmeans', [
          ('points', format_matrix(vals)),
          ('k', k),
          ('threshold', 0),
          ('max_iterations', 500),
        ])
    print(f'Created {case_exe_path}')

def prepare_hotspot():
  data_path = RODINIA_ROOT / 'data' / 'hotspot'
  data_files = [(data_path / f'temp_{size}', data_path / f'power_{size}', size)
                for size in (64, 512, 1024)]
  exe_path = EXE_ROOT / 'hotspot'
  exe_path.mkdir(parents=True, exist_ok=True)

  for (tf, pf, size) in data_files:
    with open(tf, 'r') as f:
      tvals = [l for l in f.read().split('\n') if l]
    with open(pf, 'r') as f:
      pvals = [l for l in f.read().split('\n') if l]
    ts = list(chunk(tvals, size))
    ps = list(chunk(pvals, size))

    case_exe_path = exe_path / f'{size}.dx'
    with open(case_exe_path, 'w') as f:
      emit_dex(f, 'hotspot', [
          ('numIterations', 360),
          ('T', format_matrix(ts)),
          ('P', format_matrix(ps))
        ])
      print(f'Created {case_exe_path}')

def prepare_backprop():
  exe_path = EXE_ROOT / 'backprop'
  exe_path.mkdir(parents=True, exist_ok=True)
  exe_path_ad = EXE_ROOT / 'backprop-ad'
  exe_path_ad.mkdir(parents=True, exist_ok=True)
  in_features = [512, 123]

  for inf, use_ad in product(in_features, (False, True)):
    outf = 1
    hidf = 16
    case_exe_path = (exe_path_ad if use_ad else exe_path) / f'{inf}_{hidf}_{outf}.dx'
    with open(case_exe_path, 'w') as f:
      emit_dex(f, 'backprop', [
          ('input', random_vec('in=>Float')),
          ('target', random_vec('out=>Float')),
          ('inputWeights', random_mat('{ b: Unit | w: in }=>hid=>Float')),
          ('hiddenWeights', random_mat('{ b: Unit | w: hid }=>out=>Float')),
          ('oldInputWeights', random_mat('{ b: Unit | w: in }=>hid=>Float')),
          ('oldHiddenWeights', random_mat('{ b: Unit | w: hid }=>out=>Float')),
        ], preamble=[
          ('in', f'Fin {inf}'),
          ('hid', f'Fin {hidf}'),
          ('out', f'Fin {outf}'),
        ])
      print(f'Created {case_exe_path}')

def prepare_pathfinder():
  exe_path = EXE_ROOT / 'pathfinder'
  exe_path.mkdir(parents=True, exist_ok=True)
  world_sizes = [(100, 100000)]

  for rows, cols in world_sizes:
    case_exe_path = exe_path / f'{rows}_{cols}.dx'
    with open(case_exe_path, 'w') as f:
      emit_dex(f, 'pathfinder', [
          ('world', random_mat('rows=>cols=>Int', gen='randInt')),
        ], preamble=[
          ('rows', f'Fin {rows}'),
          ('cols', f'Fin {cols}'),
        ])
      print(f'Created {case_exe_path}')

def random_vec(ty, gen='rand'):
  return f'((for i. {gen} (ixkey (newKey 0) i)) : ({ty}))'

def random_mat(ty, gen='rand'):
  return f'((for i j. {gen} (ixkey (newKey 0) (i, j))) : ({ty}))'

def chunk(l, s):
  for i in range(0, len(l), s):
    yield l[i:i + s]

def emit_dex(f, name, params, *, preamble=[]):
  for n, v in preamble:
    f.write(f'{n} = {v}\n')
  for n, v in params:
    f.write(f'{n} = {v}\n')
  f.write('\n')
  f.write(f'include "{name}.dx"\n')
  f.write('\n')
  f.write(f'%bench "{name}"\n')
  f.write(f'result = {name} {(" ".join(n for n, v in params))}\n')
  if PRINT_OUTPUTS:
    f.write('\n')
    f.write('result\n')

def format_table(l, sep=','):
  return '[' + sep.join(l) + ']'

def format_matrix(m):
  return format_table((format_table(cols) for cols in m), sep=',\n  ')

def ensure_float(s):
  if '.' not in s:
    return s + ".0"
  return s

prepare_pathfinder()
prepare_backprop()
# Verified outputs
prepare_hotspot()
prepare_kmeans()
