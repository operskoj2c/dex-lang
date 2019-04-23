Setup
=====

- Install LLVM
  sudo apt-get install llvm-6.0-dev
- Build the C extension
  make codlib.so

Workflow
========

- Compile
  stack build
  
- Repl is broken, but you can run it with
  LD_LIBRARY_PATH=.:$LD_LIBRARY_PATH stack exec coddle

- To run a file
  echo ":p 1+1" > script.cod
  LD_LIBRARY_PATH=.:$LD_LIBRARY_PATH stack exec coddle script.cod
