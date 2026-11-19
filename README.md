# rex-worktrunk

Switch to a git worktree, or create one, from [Rex](https://www.superlogical.com/rex). The `worktree` action lists the worktrees of the repo in the focused terminal and opens one Rex session for each worktree path. [worktrunk](https://github.com/max-sixty/worktrunk) (`wt`) selects or creates the worktree.

## Install

You need [worktrunk](https://github.com/max-sixty/worktrunk) (`wt`). It must support `wt list --format=json` (schema 2) and `wt switch --format=json --no-cd`.

Copy this directory to `~/.config/rex/rex-worktrunk`. The folder name has to stay `rex-worktrunk`, because that is the module name.

Add this to `~/.config/rex/init.lua`:

```lua
require("rex-worktrunk").setup{ base = "@" }
rex.bind("ctrl+space>g", "worktree")
```

Rex actions often see a short `PATH` that does not include Homebrew. The plugin looks for `wt` in `/opt/homebrew/bin/wt` and `/usr/local/bin/wt`. To pin another binary:

```lua
require("rex-worktrunk").setup{ base = "@", wt = "/opt/homebrew/bin/wt" }
```

Run `rex config reload`. Focus a terminal whose working directory is inside the repo, then press Ctrl+Space, then G.

The same action is in the command palette as **Switch or create a worktree**.

To send Ctrl+Space through to the terminal, also add:

```lua
rex.bind("ctrl+space>ctrl+space", "pane.send_key", { key = "ctrl+space" })
```

## Switch to a worktree

Run `worktree`. Rex lists each worktree from `wt list --format=json`. The title is the branch. The second line is the directory. The main checkout uses a folder icon. The worktree you are in starts selected. A row can also show dirty or prunable.

Choose a row. The plugin runs `wt switch <branch> --format=json --no-cd` in the focused terminal's directory, then shows that worktree's Rex session. Picking the same worktree again returns to the same session, including after you rename the session.

Cancel the list and nothing changes.

## Create a worktree

Choose **New worktree…**. Type a branch name and confirm **Create**. The plugin runs:

```sh
wt switch --create --base @ --no-cd --format=json <branch>
```

`@` means the branch checked out in the terminal's worktree. The new worktree then opens as its own session.

Cancel the name prompt and nothing is created. A name that is empty or only spaces is ignored. If `wt` refuses the name, the action fails with wt's message and no session is opened.

## Set the base branch

`base` is what a new branch starts from. `"@"` is the current branch. `"^"` is the default branch. A branch name is used as written. `false` omits `--base`, so wt starts from the default branch.

```lua
require("rex-worktrunk").setup{ base = "^" }
```

## Name a new session

`label` returns the session name. It is used only when the session is created. The directory name is used when `label` is absent, returns nothing, or returns something Rex rejects.

`layout` returns the `rex.layout` for that new session. The default is one shell in the worktree.

```lua
require("rex-worktrunk").setup{
  label = function(path, worktree)
    if worktree.branch then return worktree.branch end
  end,
  layout = function(label, path, worktree)
    return rex.layout.block{
      flavor = "com.superlogical.terminal.shell",
      options = { cwd = path },
    }
  end,
}
```

`worktree` has `path`, `branch`, and `main`. `main` is the primary checkout, or nil when the list did not include one.

## Open and close sessions from the command line

```sh
rex do worktree_go path=/path/to/repo.feature
rex do worktree_close path=/path/to/repo.feature main=/path/to/repo
```

`worktree_go` opens the session for that directory. `worktree_close` closes a session this plugin created. An adopted session, one that already existed when you picked its worktree, is forgotten and left open.

A key or the command palette moves the Rex window without Remote Control. `rex do` moves the window only when Remote Control is on (Rex, Settings, Rex Server).

## Close the session after wt remove

`wt remove` outside this plugin does not close the Rex session. This hook in `~/.config/worktrunk/config.toml` does:

```toml
[post-remove]
rex-session = "command -v rex >/dev/null 2>&1 && rex --autostart=false do worktree_close path={{ worktree_path }} main={{ primary_worktree_path }} >/dev/null 2>&1 || true"
```

## Run the tests

From this directory:

```sh
bash test/run.sh
```

The tests use a stand-in for Rex. They do not start a Rex server and they do not run `wt`.
