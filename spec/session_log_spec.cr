require "./spec_helper"
require "file_utils"

describe SessionLog do
  describe ".strip_flag" do
    it "retire --no-log où qu'il soit" do
      SessionLog.strip_flag(["diag", "--no-log", "aloli.fr"]).should eq({["diag", "aloli.fr"], true})
    end

    it "laisse argv tel quel sans le drapeau" do
      SessionLog.strip_flag(["diag", "aloli.fr"]).should eq({["diag", "aloli.fr"], false})
    end
  end

  describe ".path" do
    now = Time.local(2026, 10, 25, 14, 3, 7)

    it "date, heure, libellé et portée" do
      SessionLog.path("/logs", "diag", "aloli.fr", now).should eq("/logs/2026-10-25--14-03-07--diag--aloli.fr.log")
    end

    it "sans portée" do
      SessionLog.path("/logs", "etat", nil, now).should eq("/logs/2026-10-25--14-03-07--etat.log")
    end

    it "réduit libellé et portée aux caractères sûrs" do
      SessionLog.path("/logs", "mdp liste", "me+pipo@papilip.me", now)
        .should eq("/logs/2026-10-25--14-03-07--mdp_liste--me_pipo_papilip.me.log")
    end
  end

  describe ".script_args" do
    it "BSD / macOS : commande en arguments séparés" do
      SessionLog.script_args("/l.log", ["/bin/x", "a b"], linux: false).should eq(["-q", "-a", "-F", "/l.log", "/bin/x", "a b"])
    end

    it "Linux : commande en une chaîne -c, code de sortie rendu" do
      SessionLog.script_args("/l.log", ["/bin/x", "a b"], linux: true).should eq(["-q", "-a", "-e", "-c", "/bin/x 'a b'", "/l.log"])
    end
  end

  describe SessionLog::Config do
    it "dérive la variable d'environnement du nom de l'application" do
      SessionLog::Config.new("mon-outil", "1.0", "/logs").env_var.should eq("MON_OUTIL_SESSION_LOG")
    end

    it "détecte une session déjà journalisée" do
      config = SessionLog::Config.new("outil", "1.0", "/logs", env_var: "SESSION_LOG_SPEC_ACTIVE")
      config.active?.should be_false
      ENV["SESSION_LOG_SPEC_ACTIVE"] = "/x.log"
      config.active?.should be_true
    ensure
      ENV.delete("SESSION_LOG_SPEC_ACTIVE")
    end
  end

  describe ".run" do
    it "recopie sortie et erreurs dans le journal et rend le code de sortie" do
      dir = File.tempname("session-log-spec")
      begin
        config = SessionLog::Config.new("outil", "1.2.3", dir, env_var: "OUTIL_SPEC_LOG")
        log = config.path("essai")
        code = SessionLog.run(config, ["-c", "echo bonjour; echo \"$OUTIL_SPEC_LOG\"; echo erreur >&2; exit 3"], log, exe: "/bin/sh")
        code.should eq(3)
        text = File.read(log)
        text.should start_with("# outil 1.2.3 — ")
        text.should contain("bonjour\n")
        text.should contain("#{log}\n") # l'enfant connaît son journal
        text.should contain("erreur\n")
        (File.info(log).permissions.value & 0o777).should eq(0o600)
        (File.info(dir).permissions.value & 0o777).should eq(0o700)
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end

  describe ".prune" do
    it "efface les journaux trop anciens seulement" do
      dir = File.tempname("session-log-prune")
      Dir.mkdir_p(dir)
      begin
        old = File.join(dir, "vieux.log")
        recent = File.join(dir, "recent.log")
        File.write(old, "")
        File.write(recent, "")
        File.touch(old, Time.utc - 100.days)
        SessionLog.prune(dir, 90)
        File.exists?(old).should be_false
        File.exists?(recent).should be_true
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end
end
