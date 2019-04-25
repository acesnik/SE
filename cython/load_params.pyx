#
# Copyright © 2019 Ronald C. Beavis
# Licensed under Apache License, Version 2.0, January 2004
#

#
# loads and interprets command line parameters
# generates error messages and returns false if parameters fail simple tests
#
from __future__ import print_function
from libcpp cimport bool as bool_t

import os
import json

#
# loads default parameters from a JSON formatted file if the -d parameter
# is specified on the command line
# the parameters in this file are overriden by the parameters
# specified on the command line
#

def load_defaults(_param):
	if 'parameter file' not in _param:
		return _param
	if not os.path.isfile(_param['parameter file']):
		print('Parameter file "%s" not present' % (_param['parameter file']))
		return _param
	jfile = open(_param['parameter file'],'r')
	if not jfile:
		print('Parameter file "%s" could not be opened' % (_param['parameter file']))
		return _param
	js  = '';
	for j in jfile:
		js += j
	jfile.close()
	try:
		param = json.loads(js)
	except:
		print('Parameter file "%s" not a valid JSON file' % (_param['parameter file']))
		return _param
	for p in _param:
		param[p] = _param[p]
	return param

#
# loads the command line parameters from sys.argv
# tests the parameters and deals with loading
# default parameters from a specified file
#
			
def load_params(_argv):
	params = {}
	ret = True
	help = False
	additional_spectra = ''
	additional_kernels = ''
	for i,v in enumerate(_argv):
		if v.find('-h') != -1:
			ret = False
			help = True
			break
		if v.find('-') == 0:
			if i + 1 < len(_argv):
				u = _argv[i+1]
			else:
				continue
		else:
			continue
		if v.find('-c') == 0:
			params['c13'] = False
			if u == 'yes':
				params['c13'] = True
				
		if v.find('-k') == 0:
			params['kernel file'] = u
		if v.find('-F') == 0:
			try:
				params['minimum peptide frequency'] = int(u)
			except:
				print('Error: minimum peptide frequency (-F) "%s" invalid' % (u))
				ret = False
				break
		if v.find('-s') == 0:
			params['spectra file'] = u
		if v.find('-K') == 0:
			additional_kernels = u
		if v.find('-S') == 0:
			additional_spectra = u
		if v.find('-o') == 0:
			params['output file'] = u
		if v.find('-d') == 0:
			params['parameter file'] = u
		if v.find('-p') == 0:
			try:
				params['parent mass tolerance'] = int(u)
			except:
				params['parent mass tolerance'] = None
		if v.find('-f') == 0:
			try:
				params['fragment mass tolerance'] = int(u)
			except:
				params['fragment mass tolerance'] = None
		if v.find('-m') == 0:
			ms = u.split(',')
			if len(ms) > 0:
				params['mods p'] = {}
			pd = {}
			for m in ms:
				tp = m.split('@')
				mass = int(0)
				if len(tp) != 2:
					print('Error: fixed modification "%s" invalid' % (m))
					ret = False
					break
				try:
					mass = int(tp[0])
				except:
					print('Error: fixed modification "%s" invalid' %(m))
					ret = False
					break
				if tp[1] in pd:
					pd[tp[1]].append(mass)
				else:
					pd[tp[1]] = [mass]
			params['mods p'] = pd
		if v.find('-v') == 0:
			ms = u.split(',')
			if len(ms) > 0:
				params['mods v'] = {}
			pd = {}
			for m in ms:
				tp = m.split('@')
				mass = 0
				if len(tp) != 2:
					print('Error: variable modification "%s" invalid' % (m))
					ret = False
					break
				try:
					mass = int(tp[0])
				except:
					print('Error: variable modification "%s" invalid' % (m))
					ret = False
					break
				if tp[1] in pd:
					pd[tp[1]].append(mass)
				else:
					pd[tp[1]] = [mass]
			params['mods v'] = pd
		if v.find('-h') != -1:
			ret = False
			help = True
	if len(_argv) == 1:
		help = True
		ret = False
	if help:
		print('''
	>python3 se.py -k KERNEL -s SPECTRA (-d FILE) (-p 20) (-f 400) (-F 1) (-o FILE)  (-h) (-c V) (-p FIXED) (-v VAR)
	   where:
		   -c: use C13 isotope-error testing (yes/no)
		   -d: default parameter file (JSON)
		   -f: fragment mass tolerance in mDa (400)
		   -F: minimum peptide frequency (1)
	           -h: show the help page (overrides all other commands)
	           -k: proteome kernel file list (FILE(,FILE2,FILE3,...))
		   -K: additional kernel file list (FILE(,FILE2,FILE3,...))
		   -o: output file name 
		         formats: tab-separated values
		   -p: parent mass tolerance in ppm (20)
		   -s: spectrum file list (FILE(,FILE2,FILE3,...)
		         formats: JSMS, MGF or mzML
		   -S: additional spectrum file list (FILE(,FILE2,FILE3,...))
		         formats: JSMS, MGF or mzML
		   -m: fixed modifications list (MASS1@X,MASS2@Y ...)
		   -v: variable modifications list (MASS1@X,MASS2@Y ...)
''')
		return (params,False)
#
#	load parameters file, if -d specified
#
#	print(params)
	params = load_defaults(params)
#	print(params)
#
#	test parameters for obvious problems
#
	pval = 'parent mass tolerance'
	if pval in params and (params[pval] is None or params[pval] < 1) :
		print('''Error: %s (-p) bad value\n   must be an integer > 0''' % (pval))
		ret = False
	pval = 'fragment mass tolerance'
	if pval in params and (params[pval] is None or params[pval] < 1) :
		print('''Error: %s (-f) bad value\n   must be an integer > 0''' % (pval))
		ret = False
#
#	add in any default values that may have been missed
#
	para_min = {'fragment mass tolerance': 400,
		'parent mass tolerance': 10,
		'minimum peptide frequency': 1,
		'mods p': {'C':[57021],'U':[57021]},
		'mods v': {'M':[15995]},
		'mods o': {'nt-ammonia':True,'nt-water':True},
		'c13': False,
		'output valid only': False}
	for p in para_min:
		if p not in params:
			params[p] = para_min[p]
	if ret:
		print('.')
	if 'kernel file' in params:
		if len(additional_kernels) > 0:
			params['kernel file'] += ',%s' % additional_kernels
	elif len(additional_kernels) > 0:
		params['kernel file'] = '%s' % additional_kernels

	if 'spectra file' in params:
		if len(additional_spectra) > 0:
			params['spectra file'] += ',%s' % additional_spectra

	elif len(additional_spectra) > 0:
		params['spectra file'] += '%s' % additional_spectra
	pval = 'kernel file'
	if pval not in params:
		print(''' no %s (-k) specified on command line or default file''' % (pval))
		ret = False
	if pval in params:
		kfs = params[pval].split(',')
		for k in kfs:
			if not os.path.isfile(k):
				print('''Error: %s (-k/K) "%s" does not exist''' % (pval,k))
				ret = False
	pval = 'spectra file'
	if pval not in params:
		print(''' no %s (-s) specified on command line or default file''' % (pval))
		ret = False
	if pval in params:
		sfs = params[pval].split(',')
		for s in sfs:
			if not os.path.isfile(s):
				print('''Error: %s (-s/S) "%s" does not exist''' % (pval,s))
				ret = False
	return (params,ret)

