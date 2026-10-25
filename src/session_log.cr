require "./session_log/version"

# Journal de session pour les CLI Crystal : le programme se RELANCE lui-même
# et le parent enregistre dans un fichier tout ce qui s'affiche dans le
# terminal (questions, réponses, sortie des sous-processus).
#
# * Terminal interactif : l'enfant tourne sous `script(1)`, qui lui garde un
#   vrai terminal (questions, couleurs, `tty?`, saisie sans écho, `ssh -t`
#   intacts) et enregistre la session dans le fichier.
# * Sortie redirigée (tube, cron) : l'enfant écrit dans deux tubes que le
#   parent recopie à la fois à l'écran et dans le fichier.
#
# L'enfant reçoit la variable `<APP>_SESSION_LOG` (chemin du journal) : il ne
# se relance pas une seconde fois, ses propres enfants non plus. Fichiers
# 0600 dans un dossier 0700 ; journaux de plus de `keep_days` jours effacés à
# chaque nouvelle session journalisée.
#
# Le choix des commandes à journaliser (et de leur libellé) revient à
# l'application : JAMAIS celles qui affichent ou font saisir des secrets en
# clair — un journal ne doit pas devenir une copie du coffre.
#
# ```
# require "session-log"
#
# log = SessionLog::Config.new("monoutil", MonOutil::VERSION, "#{ENV["HOME"]}/.local/state/monoutil/logs")
# argv, refused = SessionLog.strip_flag(ARGV)
# if !refused && !log.active? && journaliser?(argv)
#   exit SessionLog.run(log, argv, log.path(argv.first, argv[1]?))
# end
# exit MonOutil.run(argv)
# ```
module SessionLog
  extend self

  # Option qui refuse le journal, où qu'elle soit sur la ligne de commande.
  FLAG = "--no-log"

  # Paramètres propres à une application.
  struct Config
    getter app : String
    getter version : String
    getter dir : String
    getter env_var : String
    getter keep_days : Int32

    # `env_var` par défaut : `MONOUTIL_SESSION_LOG` pour l'application
    # `monoutil`.
    def initialize(@app : String, @version : String, @dir : String, env_var : String? = nil, @keep_days : Int32 = 90)
      @env_var = env_var || "#{@app.upcase.gsub(/[^A-Z0-9]/, "_")}_SESSION_LOG"
    end

    # Déjà sous journal (variable héritée du parent) ?
    def active? : Bool
      !ENV[@env_var]?.presence.nil?
    end

    # Chemin du journal de cette session (voir `SessionLog.path`).
    def path(label : String, scope : String? = nil, now : Time = Time.local) : String
      SessionLog.path(@dir, label, scope, now)
    end
  end

  # Retire `--no-log` d'argv (où qu'il soit). Renvoie {argv nettoyé,
  # journal refusé ?}. Pur.
  def strip_flag(argv : Array(String), flag : String = FLAG) : {Array(String), Bool}
    {argv.reject(flag), argv.includes?(flag)}
  end

  # `<dossier>/2026-10-25--14-03-07--diag--aloli.fr.log` : date, heure,
  # libellé de la commande, puis la portée (un domaine, un hôte…) réduite aux
  # caractères sûrs dans un nom de fichier. Pur.
  def path(dir : String, label : String, scope : String? = nil, now : Time = Time.local) : String
    name = "#{now.to_s("%Y-%m-%d--%H-%M-%S")}--#{safe(label)}"
    if scope && !(s = safe(scope)).empty?
      name = "#{name}--#{s}"
    end
    File.join(dir, "#{name}.log")
  end

  # Arguments de `script(1)` : enregistre (en ajout, l'en-tête est déjà
  # écrit) la commande `cmd` dans `log`. BSD et macOS : `script -q -a -F log
  # cmd…` (`-F` : écrit au fil de l'eau, `tail -f` possible ; code de sortie =
  # celui de la commande). Linux (util-linux) : commande en une chaîne `-c`,
  # `-e` pour rendre son code de sortie. Pur.
  def script_args(log : String, cmd : Array(String), linux : Bool = {{ flag?(:linux) }}) : Array(String)
    if linux
      ["-q", "-a", "-e", "-c", cmd.map { |a| Process.quote(a) }.join(" "), log]
    else
      ["-q", "-a", "-F", log] + cmd
    end
  end

  # Relance le programme (`argv` complet, options globales comprises) sous
  # journal et renvoie son code de sortie. Le chemin du journal est rappelé
  # sur stderr à la fin. `exe` : le programme lui-même par défaut.
  def run(config : Config, argv : Array(String), log : String, exe : String = Process.executable_path || PROGRAM_NAME) : Int32
    dir = File.dirname(log)
    Dir.mkdir_p(dir)
    File.chmod(dir, 0o700)
    prune(dir, config.keep_days)
    File.write(log, header(config, argv), perm: 0o600)

    env = {config.env_var => log}
    script = Process.find_executable("script")
    code =
      if script && STDIN.tty? && STDOUT.tty?
        Process.run(script, script_args(log, [exe] + argv), env: env,
          input: Process::Redirect::Inherit, output: Process::Redirect::Inherit, error: Process::Redirect::Inherit).exit_code
      else
        run_teed(exe, argv, env, log)
      end
    STDERR.puts "journal : #{log}"
    code
  end

  # En-tête du journal : programme, version, date, ligne de commande. Pur.
  def header(config : Config, argv : Array(String), now : Time = Time.local) : String
    "# #{config.app} #{config.version} — #{now.to_s("%Y-%m-%d %H:%M:%S %:z")}\n# #{config.app} #{argv.join(" ")}\n\n"
  end

  # Efface les journaux de plus de `keep_days` jours. Jamais bloquant.
  def prune(dir : String, keep_days : Int32) : Nil
    limit = Time.utc - keep_days.days
    Dir.glob(File.join(dir, "*.log")).each do |f|
      File.delete(f) if File.info(f).modification_time < limit
    end
  rescue
  end

  private def safe(text : String) : String
    text.gsub(/[^A-Za-z0-9._-]/, "_")[0, 80]
  end

  # Sortie redirigée : stdout et stderr de l'enfant recopiés à l'écran ET
  # dans le journal, morceau par morceau (une question sans fin de ligne
  # s'affiche tout de suite).
  private def run_teed(exe : String, argv : Array(String), env : Hash(String, String), log : String) : Int32
    File.open(log, "a") do |file|
      file.sync = true
      process = Process.new(exe, argv, env: env, input: Process::Redirect::Inherit,
        output: Process::Redirect::Pipe, error: Process::Redirect::Pipe)
      done = Channel(Nil).new
      {% for pair in [{"output", "STDOUT"}, {"error", "STDERR"}] %}
        spawn do
          buf = Bytes.new(4096)
          while (n = process.{{ pair[0].id }}.read(buf)) > 0
            {{ pair[1].id }}.write(buf[0, n])
            {{ pair[1].id }}.flush
            file.write(buf[0, n])
          end
          done.send(nil)
        end
      {% end %}
      2.times { done.receive }
      process.wait.exit_code
    end
  end
end
