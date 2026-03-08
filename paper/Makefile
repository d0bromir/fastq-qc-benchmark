# Makefile for compiling the benchmark paper
MAIN    = main
LATEX   = pdflatex
BIBTEX  = bibtex

.PHONY: all clean distclean

all: $(MAIN).pdf

$(MAIN).pdf: $(MAIN).tex
	$(LATEX) -interaction=nonstopmode $(MAIN).tex
	$(LATEX) -interaction=nonstopmode $(MAIN).tex
	$(LATEX) -interaction=nonstopmode $(MAIN).tex

clean:
	rm -f *.aux *.log *.out *.toc *.lof *.lot *.bbl *.blg *.nav *.snm *.fls *.fdb_latexmk

distclean: clean
	rm -f $(MAIN).pdf
