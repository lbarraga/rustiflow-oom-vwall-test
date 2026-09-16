# rustiflow-vwall — operator commands. Run `just` for the list.
#
# SSH targets come from the jFed manifest after swap-in (user@hostname). Pass
# them on the CLI, e.g.:
#   just check victim=me@n081-01.wall2.ilabt.iminds.be attacker=me@n081-02.wall2.ilabt.iminds.be
# or export VICTIM=... ATTACKER=... once.

set dotenv-load := true
set dotenv-filename := "config.env"

slice    := env_var_or_default("SLICE", "rustiflow-preflight")
duration := env_var_or_default("DURATION", "4")          # hours
victim   := env_var_or_default("VICTIM", "")             # user@host
attacker := env_var_or_default("ATTACKER", "")           # user@host
ssh_opts := "-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15"

_default:
    @just --list

# --- provisioning ----------------------------------------------------------

# Swap the topology in via the jFed CLI (or just load rspec/preflight.rspec in the jFed GUI).
up:
    @echo "Swapping in slice '{{slice}}' from rspec/preflight.rspec ..."
    @echo "Requires the jFed CLI configured with your certificate. Exact flags vary by version:"
    @echo "  jfed-cli create -S {{slice}} --rspec rspec/preflight.rspec --duration {{duration}} -m ./manifest"
    @echo "GUI alternative: open jFed -> New -> Import rspec/preflight.rspec -> Run."

# Poll both nodes until bootstrap.sh reports READY (needs victim= and attacker=).
wait:
    @test -n "{{victim}}" -a -n "{{attacker}}" || { echo "set victim= and attacker="; exit 1; }
    @for tgt in "{{victim}}" "{{attacker}}"; do \
      echo "waiting for $tgt ..."; \
      until ssh {{ssh_opts}} "$tgt" "cat $MARKER_DIR/*.status 2>/dev/null | grep -q READY"; do \
        ssh {{ssh_opts}} "$tgt" "cat $MARKER_DIR/*.status 2>/dev/null || echo '  (no marker yet)'"; \
        sleep 20; \
      done; \
      echo "  $tgt READY"; \
    done

# Re-run bootstrap on a node by hand (host=user@... role=victim|attacker).
provision host role:
    ssh {{ssh_opts}} "{{host}}" "cd $VWALL_DIR && git pull --ff-only && ./bootstrap.sh {{role}}"

# --- the experiment (smoke test) -------------------------------------------

# Run the preflight on both nodes over SSH and print both reports.
check:
    @test -n "{{victim}}" -a -n "{{attacker}}" || { echo "set victim= and attacker="; exit 1; }
    @echo "== starting victim (server + capture) =="
    ssh {{ssh_opts}} "{{victim}}" "cd $VWALL_DIR && nohup ./preflight.sh victim > /local/preflight-victim.log 2>&1 & echo started"
    @sleep 3
    @echo "== running attacker (drives ping/iperf, reports) =="
    ssh {{ssh_opts}} "{{attacker}}" "cd $VWALL_DIR && ./preflight.sh attacker"
    @echo "== victim report =="
    ssh {{ssh_opts}} "{{victim}}" "cat /local/preflight-victim.log"

# Print the manual two-terminal sequence (no SSH orchestration).
manual:
    @echo "Terminal 1 (victim):    cd {{justfile_directory()}} && ./preflight.sh victim"
    @echo "Terminal 2 (attacker):  cd {{justfile_directory()}} && ./preflight.sh attacker   # within ${CAP_SECS}s"

# --- experiment results ----------------------------------------------------

# Summarize an OOM run's CSVs. Runs summarize.sh on a node that has the share
# mounted. Pass exp=<slice> (default: the node's own) and host= or victim=.
results exp="":
    @tgt="{{victim}}"; test -n "$tgt" || { echo "set victim=user@node (or host in your ssh config)"; exit 1; }; \
     ssh {{ssh_opts}} "$tgt" "cd $VWALL_DIR && ./experiment/summarize.sh {{exp}}"

# Watch a live run's progress on both nodes.
watch:
    @test -n "{{victim}}" -a -n "{{attacker}}" || { echo "set victim= and attacker="; exit 1; }
    @echo "== victim =="; ssh {{ssh_opts}} "{{victim}}" "tail -n 20 /local/experiment.log 2>/dev/null || echo 'no experiment log yet'"
    @echo "== attacker =="; ssh {{ssh_opts}} "{{attacker}}" "tail -n 20 /local/experiment.log 2>/dev/null || echo 'no experiment log yet'"

# --- teardown --------------------------------------------------------------

down:
    @echo "Terminate slice '{{slice}}' in jFed, or:  jfed-cli delete -S {{slice}}"

# --- local checks ----------------------------------------------------------

# Lint the shell scripts (needs shellcheck; `nix develop` provides it).
lint:
    shellcheck -x lib.sh bootstrap.sh preflight.sh
