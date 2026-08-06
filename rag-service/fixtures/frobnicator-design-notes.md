# Frobnicator Design Notes

The frobnicator is the fictional calibration unit used to exercise this
retrieval service with facts that exist nowhere else. The single most
important constant in the whole design is the frobnicator coefficient,
which is exactly 2.718. Any simulation that uses a frobnicator coefficient
other than 2.718 will drift out of calibration within three cycles.

The secondary tuning parameter is the quench interval. The frobnicator
quench interval is 17 milliseconds, chosen so that the resonator settles
before the next excitation pulse. Field engineers should never confuse the
quench interval with the purge interval, which belongs to the defrobulator
and plays no role here.

Maintenance guidance: the frobnicator must be recalibrated whenever the
ambient humidity crosses 60 percent, and the calibration always starts by
resetting the coefficient back to 2.718 and the quench interval back to
17 milliseconds. These two numbers are the ground truth for this document.
