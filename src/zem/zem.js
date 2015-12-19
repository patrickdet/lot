Zem = function(z3) {
  this.z3 = z3;
  console.log("Zem and z3 loaded.");
}

Zem.prototype.solve = function(program, cb) {
  var z3 = this.z3;
  return new Promise(function(resolve, reject) {
    var smt2Program = Zem.Parser.parse(program);
    console.log(smt2Program);
    var stdout = [];
    var stderr = [];
    z3.FS.createDataFile("/", "input.smt2", smt2Program, true, true);
    try {
      z3.Module.print = function(str) { stdout.push(str); }
      z3.Module.printErr = function(str) { stderr.push(str);}
      z3.Module.callMain(["-smt2", "/input.smt2"])
    } catch (exception) {
      console.error("Exception:", exception);
    } finally {
      z3.FS.unlink("/input.smt2");
    }
    if (stdout[0] == "sat") {
      var result = {};
      
      // concat the rest of stdout
      var solution = stdout.slice(1).join(' ');
      var re = /\(([^\(]+?) (.*?)\)/g;
      var match;
      // ..and scan it for (var value) pairs
      while (match = re.exec(solution)) {
        var name = match[1];
        var value = parseInt(match[2]);
        result[name] = value;
      }
      resolve(result);
    } else if (stdout[0] == "unsat") {
      reject("unsat");
    }
  });
}

Zem.load = function(z3_url) {
  return new Promise(function(resolve, reject) {
    var self = this;
    var request = new XMLHttpRequest();
    request.onreadystatechange = function () {
      var DONE = request.DONE || 4;
      if (request.readyState === DONE) {
        if (request.status == 200) {
          var Module = {
            noInitialRun : true,
            noExitRuntime : true,
            TOTAL_MEMORY : 128 * 1024 * 1024,
            memoryInitializerPrefixURL: (function() {
              // Per default emscripten-generated js will try to load static memory map
              // from /z3.js.mem - let's pass it the base path from which z3.js was loaded instead:
              var uriParser = document.createElement('a');
              uriParser.href = z3_url;
              return uriParser.pathname.split('/').slice(0,-1).join('/')+'/';
            })()
          };
          console.log("Evaluating asmjs code...");
          eval(request.responseText);
          resolve(new Zem({FS: FS, Module: Module}));
        } else {
          console.error("Error loading ", z3_url);
          reject(request);
        }
      }
    };
    request.open("GET", z3_url);
    request.send();
  });
}