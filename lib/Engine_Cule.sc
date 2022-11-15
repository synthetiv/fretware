Engine_Cule : CroneEngine {

	// TODO: replace or augment buses with buffers
	// var ampBus;
	// var freqBus;
	var synth;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	alloc {

		// ampBus = Bus.control(context.server);
		// freqBus = Bus.control(context.server);

		SynthDef.new(\line, {
			arg octave = 0, hz = 440, hzlag = 0.01, fb = 0, fblag = 0.1, fold = 0.3, foldlag = 0.1, amp = 0, amplag = 0.1;

			var sine, folded;

			hz = Lag.kr(hz, hzlag);
			amp = Lag.kr(amp, amplag);
			fb = Lag.kr(fb, fblag);
			fold = Lag.kr(fold, foldlag);

			sine = SinOscFB.ar(2.pow(octave) * hz, fb);
			folded = SinOsc.ar(0, pi * fold * sine) * amp;
			Out.ar(context.out_b, folded ! 2);
		}).add;

		context.server.sync;

		synth = Synth.new(\line, [
			\in_l, context.in_b[0],
			\in_r, context.in_b[1]
		], context.og); // "output" group

		this.addCommand(\hz, "f", {
			arg msg;
			synth.set(\hz, msg[1]);
		});

		this.addCommand(\hzlag, "f", {
			arg msg;
			synth.set(\hzlag, msg[1]);
		});

		this.addCommand(\amp, "f", {
			arg msg;
			synth.set(\amp, msg[1]);
		});

		this.addCommand(\amplag, "f", {
			arg msg;
			synth.set(\amplag, msg[1]);
		});

		this.addCommand(\fb, "f", {
			arg msg;
			synth.set(\fb, msg[1]);
		});

		this.addCommand(\fold, "f", {
			arg msg;
			synth.set(\fold, msg[1]);
		});

		this.addCommand(\octave, "i", {
			arg msg;
			synth.set(\octave, msg[1]);
		});
	}

	free {
		synth.free;
		// ampBus.free;
		// freqBus.free;
	}
}
