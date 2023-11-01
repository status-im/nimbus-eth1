# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  ./step

# A step that runs two or more steps in parallel
type ParallelSteps struct {
  Steps []TestStep
}

func (step ParallelSteps) Execute(t *CancunTestContext) error {
  # Run the steps in parallel
  wg = sync.WaitGroup{}
  errs = make(chan error, len(step.Steps))
  for _, s = range step.Steps {
    wg.Add(1)
    go func(s TestStep) {
      defer wg.Done()
      if err = s.Execute(t); err != nil {
        errs <- err
      }
    }(s)
  }
  wg.Wait()
  close(errs)
  for err = range errs {
    return err
  }
  return nil
}

func (step ParallelSteps) Description() string {
  desc = "ParallelSteps: running steps in parallel:\n"
  for i, step = range step.Steps {
    desc += fmt.Sprintf("%d: %s\n", i, step.Description())
  }

  return desc
}