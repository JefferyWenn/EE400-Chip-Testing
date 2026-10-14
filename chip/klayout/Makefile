ARTIFACTS := ../../artifacts/gds

# Final PAR output (Jun 6, matches final RTL)
open-presignoff:
	klayout -l  ./tsm180.lyp $(ARTIFACTS)/chip_top.gds

# Signoff GDS with seal ring, dummy fill and logo
open-signoff-logo:
	klayout -l  ./tsm180.lyp $(ARTIFACTS)/chip_top_signoff_logo.gds

open-signoff: open-signoff-logo
