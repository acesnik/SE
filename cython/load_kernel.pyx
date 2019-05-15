#
# Copyright © 2019 Ronald C. Beavis
# Licensed under Apache License, Version 2.0, January 2004
#

#
# contains methods for loading and editing sequence kernels
# Reads kernels in either plain text or gzip'd text
#

#
# uncomment the next 2 imports for Cython
#
from __future__ import print_function
from libcpp cimport bool as bool_t
import ujson
#import json
import re
import gzip
import sys
import itertools
import copy
#from libc.math cimport abs as m_abs

#
# method to import a list of isotopic masses necessary to do some of the calculations.
# if 'isotopes.txt' is not available, a warning is thrown and a default list is used.
#
cdef dict load_isotopes():
	try:
		f = open('isotopes.txt','r')
	except:
		print('Warning: isotopes.txt is not available so default values used')
		return { 'p':1.007276,'1H':1.007825,'2H':2.014102,'12C':12.0,'13C':13.003355,'14N':14.003074,
		 	'16O':15.994915,'32S':31.972072 }
	cdef dict iso = {}
	for l in f:
		l = l.strip()
		vs = l.split('\t')
		if len(vs) < 2:
			continue
		iso[vs[0]] = float(vs[1])
	f.close()
	return iso
#
# method to generate a list of kernels that are potential matches for the input list of spectra (_s)
# the kernels are read from a file (_f) and a set of parameters (_param) govern the way that
# kernels should be tested and modified, based on the experiment that was performed
# this method is the only one called externally
#

def load_kernel(str _f,list _s,dict _param,long _qi):
	cdef long freq = 1
	if 'minimum peptide frequency' in _param:
		freq = int(_param['minimum peptide frequency'])
	cdef dict labels = {}
	cdef long r = 0
	(qs,qm,spectrum_list,t,qn,rc) = load_kernel_main(_f,_s,_param,_qi,freq,labels,r)
	return (qs,qm,spectrum_list,t,qn,rc)

cdef tuple load_kernel_main(str _f,list _s,dict _param,long _qi,long _freq,dict _labels,long _r):
	cdef dict redundancy = {}
	cdef set motif_proteins = set([])
	cdef dict isotopes = load_isotopes()
	if _f.find('.gz') == len(_f) - 3:
		f = gzip.open(_f,'rt', encoding='utf-8')
	else:
		f = open(_f,'r', encoding='utf-8')
#
#	set kernel offset when loading multiple kernel files
#
	cdef long qn = _qi
	cdef list sms_list = []
	cdef dict sp = {}
	for sp in _s:
		sms_list.append(set(sp['sms']))

#
# 	retrieve information from the _param dictionary and
#	create faster local variables
#
	cdef long default_depth = 3
	cdef long len_labels = len(_labels)
	if 'ptm depth' in _param:
		default_depth = _param.get('ptm depth')
	if default_depth > 10:
		default_depth = 10
	cdef long res = 50
	cdef double max_ppm = float(_param.get('parent mass tolerance'))*1.0e-6
	cdef double min_ppm = -1.0*max_ppm
	cdef double ppm = 0.0
	cdef double ires = float(res)
	cdef double fres = float(_param.get('fragment mass tolerance'))
	nt_ammonia = True
	if 'nt-ammonia' in _param['mods o']:
		nt_ammonia = _param['mods o']['nt-ammonia']
	nt_water = True
	if 'nt-water' in _param['mods o']:
		nt_water = _param['mods o']['nt-water']
	use_c13 = True
	if 'c13' in _param:
		use_c13 = _param.get('c13')
	cdef long acetyl = 42011
	cdef dict p_mods = {}
	cdef dict v_mods = {}
	if 'mods p' in _param:
		p_mods = _param.get('mods p')
	if 'mods v' in _param:
		default_v_mods = _param.get('mods v')
#
# 	create local variables for specific masses
#
	cdef long ammonia = normalize(isotopes.get('14N') + 3*isotopes.get('1H'))
	cdef long water = normalize(isotopes.get('16O') + 2*isotopes.get('1H'))
	cdef long c13 = normalize(isotopes.get('13C') - isotopes.get('12C'))
#
# 	initialize some variable outside of the main iteration
#
	cdef long t = 0
	cdef list pms = []
	cdef list qs = []
	cdef list qm = []
	cdef dict spectrum_list = {}
	cdef dict p_pos = {}
	cdef dict v_pos = {}
	(s_index,s_masses) = create_index(_s,ires)
#
# 	show activity to the user
#
	print('.',end='')
	sys.stdout.flush()

	cdef long lp_len = 0
	if p_mods:
		for v in p_mods:
			lp_len = len(p_mods[v])
			break
	cdef list isIaa = [0]*lp_len
	if 'C' in p_mods:
		for i in range(len(p_mods['C'])):
			if p_mods['C'][i] == 57021:
				isIaa[i] = True
			else:
				isIaa[i] = False
	cdef long p_total = 0
	cdef long d_value = 0
	cdef long tmass = 0
	cdef long delta = 0
	cdef long c = 0
	cdef long c_limit = 5
	cdef long pm = 0
	cdef long beg = 0
	cdef str seq = ''
	cdef str pre = ''
	cdef long s = 0
	q_ammonia_loss = False
	c_ammonia_loss = False
	water_loss = False
	ok = False
	bIaa = False
	appended = False
	cdef long r_count = 0
	cdef int r_value = 0
	cdef int r_value_a = 0
	cdef int r_value_q = 0
	for l in f:
#
# 		show activity to the user
#
		if t % 10000 == 0:
			print('.',end='')
			sys.stdout.flush()
		v_pos = {}
#
# 		retrieve kernel mass, protein coordinate and peptide sequence
#		this is much faster than doing a jsons.loads at this point
#
		js_master = ujson.loads(l)
		if 'pm' not in js_master:
			continue
		if _r == 0:
			if sum(js_master['ns']) < _freq:
				continue
		pm = js_master['pm']
		beg = js_master['beg']
		seq = js_master['seq']
		pre = js_master['pre']

		n_term = seq[:1]
		r_value = 2
		if 'sav' not in js_master:
			r_value = check_redundancy(seq,redundancy,qs,js_master)
		r_value_a = 0
		if beg < 4 and 'LIFWQYHKR'.find(n_term) == -1:
			r_value_a = check_redundancy(seq+'+a',redundancy,qs,js_master)

		q_ammonia_loss = False
		c_ammonia_loss = False
		if nt_ammonia and n_term == 'Q':
			q_ammonia_loss = True
		if nt_ammonia and n_term == 'C':
			c_ammonia_loss = True
		water_loss = False
		if nt_water and n_term == 'E':
			water_loss = True
		r_value_q = 0
		if q_ammonia_loss or c_ammonia_loss or water_loss:
			r_value_q = check_redundancy(seq+'+q',redundancy,qs,js_master)

		if r_value != 2 and r_value_a != 2 and r_value_q != 2:
			r_count += 1
			t += 1
			continue
#
# 		generate fixed modification information
#
		(lp_pos,lp_total) = generate_lpstack(p_mods,seq,lp_len)
#
# 		generate variable modification information
#
		
		(v_mods,depth) = check_motifs(seq,default_v_mods,default_depth)
		v_pos = generate_vd(v_mods,seq,pre)
		v_stack = generate_vstack(v_mods,v_pos,depth)

		ok = False
		delta = 0
		b_mods = []
		y_mods = []
#
#		Make copies of the arrays in js_master
#
		js_bs = list(js_master['bs'])
		js_ys = list(js_master['ys'])
		js_pm = js_master['pm']
		testAcetyl = False
		testWater = False
		for lp in range(lp_len):
			bIaa = False
			if 'C' in p_mods:
				bIaa = isIaa[lp]
			if c_ammonia_loss and not bIaa:
				c_ammonia_loss = 0
			for vp in v_stack:
				b_mods = []
				y_mods = []
				vs_pos = vp[0]
				vs_total= vp[1]
				p_pos = lp_pos[lp]
				p_total = lp_total[lp]+vs_total
				tmass = pm+p_total
				if r_value == 2:
					if use_c13 and tmass > 1500000:
						pms = get_spectra(s_index,tmass,ires,[c13])
					else:
						pms = get_spectra(s_index,tmass,ires,[])
				else:
					pms = []
				appended = False
				jv = None
				jc = None
				delta = 0
				for s in pms:
					delta = s_masses[s]-tmass
					if(delta > 900):
						ppm = float(delta-c13)/tmass
					else:
						ppm = float(delta)/tmass
					if min_ppm < ppm < max_ppm:
						if jv is None:
							(jv,jm) = load_json(js_master,p_pos,p_mods,b_mods,y_mods,lp,vs_pos,v_mods,fres)
#
#							replace arrays in js_master
#
							js_master['bs'] = list(js_bs)
							js_master['ys'] = list(js_ys)
							js_master['pm'] = js_pm
							js_master['mods'] = []
						sms = sms_list[s]
						c = 0
						for k in jm:
							if k in sms:
								c += 1
						if c >= c_limit:
							if not appended:
								qs.append(jv)
								if seq in redundancy and redundancy[seq] is not None:
									redundancy[seq].append(len(qs) - 1)
								else:
									redundancy[seq]= [len(qs) - 1]				
								qm.append(jm)
								appended = True
								_labels[js_master['lb']] = 1
							if s not in spectrum_list:
								spectrum_list[s] = []
							spectrum_list[s].append(qn)
				if appended:
					qn += 1
				appended = False
				if '[' in p_mods:
					if p_mods['['][lp] != 0:
						continue
				if beg < 4 and 'LIFWQYHKR'.find(n_term) == -1:
					b_mods = []
					y_mods = []
					testAcetyl = True
					tmass = pm+p_total+acetyl
					if use_c13 and tmass > 1500000:
						pms = get_spectra(s_index,tmass,ires,[c13])
					else:
						pms = get_spectra(s_index,tmass,ires,[])
					jv = None
					jc = None
					for s in pms:
						delta = s_masses[s]-pm-p_total-acetyl
						if(delta > 900):
							ppm = float(delta-c13)/tmass
						else:
							ppm = float(delta)/tmass
						if min_ppm < ppm < max_ppm:
							if acetyl not in b_mods:
								b_mods.append(acetyl)
							if jv is None:
								(jv,jm) = load_json(js_master,p_pos,p_mods,b_mods,y_mods,lp,vs_pos,v_mods,fres)
#
#								replace arrays in js_master
#
								js_master['bs'] = list(js_bs)
								js_master['ys'] = list(js_ys)
								js_master['pm'] = js_pm
								js_master['mods'] = []
							sms = sms_list[s]
							c = 0
							for k in jm:
								if k in sms:
									c += 1
							if c >= c_limit:
								if not appended:
									qs.append(jv)
									if seq+'+a' in redundancy:
										redundancy[seq+'+a'].append(len(qs) - 1)
									else:
										redundancy[seq+'+a']= [len(qs) - 1]				
									qm.append(jm)
									_labels[js_master['lb']] = 1
									appended = True
								if s not in spectrum_list:
									spectrum_list[s] = []
								spectrum_list[s].append(qn)

				if appended:
					qn += 1
				appended = False
				if q_ammonia_loss or c_ammonia_loss or water_loss:
					b_mods = []
					y_mods = []
					testWater = True
					dvalue = ammonia
					if water_loss:
						dvalue = water
					tmass = pm+p_total-dvalue
					if use_c13 and tmass > 1500000:
						pms = get_spectra(s_index,tmass,ires,[c13])
					else:
						pms = get_spectra(s_index,tmass,ires,[])
					jv = None
					jc = None
					for s in pms:
						delta = s_masses[s]-pm-p_total+dvalue
						if(delta > 900):
							ppm = float(delta-c13)/tmass
						else:
							ppm = float(delta)/tmass
						if min_ppm < ppm < max_ppm:
							if dvalue not in b_mods:
								b_mods.append(-1*dvalue)
							if jv is None:
								(jv,jm) = load_json(js_master,p_pos,p_mods,b_mods,y_mods,lp,vs_pos,v_mods,fres)
#
#								replace arrays in js_master
#
								js_master['bs'] = list(js_bs)
								js_master['ys'] = list(js_ys)
								js_master['pm'] = js_pm
								js_master['mods'] = []
							sms = sms_list[s]
							c = 0
							for k in jm:
								if k in sms:
									c += 1
							if c >= c_limit:
								if not appended:
									qs.append(jv)
									if seq+'+q' in redundancy:
										redundancy[seq+'+q'].append(len(qs) - 1)
									else:
										redundancy[seq+'+q']= [len(qs) - 1]				
									qm.append(jm)
									_labels[js_master['lb']] = 1
									appended = True
								if s not in spectrum_list:
									spectrum_list[s] = []
								spectrum_list[s].append(qn)

				if appended:
					qn += 1

		if seq not in redundancy:
			redundancy[seq] = None
		if testWater and seq+'+q' not in redundancy:
			redundancy[seq+'+q'] = None
		if testAcetyl and seq+'+a' not in redundancy:
			redundancy[seq+'+a'] = None
		t += 1
	return (qs,qm,spectrum_list,t,qn,r_count)

cdef int check_redundancy(str _seq,dict _redundancy,list _qs,dict _js):
	if _seq in _redundancy:
		if _redundancy[_seq] is None:
			return 0
		vs = _redundancy[_seq]
		for v in vs:
			if 'vlb' not in _qs[v]:
				_qs[v]['vlb'] = [_js['lb']]
				_qs[v]['vpre'] = [_js['pre']]
				_qs[v]['vpost'] = [_js['post']]
				_qs[v]['vbeg'] = [_js['beg']]
				_qs[v]['vend'] = [_js['end']]
			else:
				_qs[v]['vlb'].append(_js['lb'])
				_qs[v]['vpre'].append(_js['pre'])
				_qs[v]['vpost'].append(_js['post'])
				_qs[v]['vbeg'].append(_js['beg'])
				_qs[v]['vend'].append(_js['end'])
		return 1
	return 2

cdef tuple check_motifs(str _seq,dict _d_mods,long _depth):
	cdef long dcoll = len(re.findall('(?=(G.PG))', _seq))
	cdef long dng = _seq.find('NG')
	cdef dict v_mods = _d_mods
	cdef long depth = _depth
	if dcoll > 1 or dng != -1:
		v_mods = copy.deepcopy(_d_mods)
		if dcoll > 1 and 'P' not in v_mods:
			v_mods['P'] = [15995]
			depth = dcoll
			if depth > 5:
				depth = 5
		elif dng != -1 and 'N' not in v_mods:
			v_mods['N'] = [984]
	return (v_mods,depth)

#
# method to convert floating point masses in Daltons to integer masses in milliDaltons
#

cdef long normalize(_v):
	return int(round(1000*_v,0))

#
# method to create an array with each possible variable modification state
# in a single element
#

cdef list generate_vstack(dict _mods,dict _pos,long _depth = 3):
	cdef list v_stack = []
	cdef dict vs_pos = {}
	cdef list master_list = []
#
#	create an empty vs_pos dict (unmodified)
#	and generate a list of the possible modifications
#	where each element is a tuple of (residue,position)
#
	cdef str v = ''
	for v in _mods:
		vs_pos[v] = []
		if v not in _pos:
			continue
		else:
			for p in _pos[v]:
				master_list.append((v,p))
	cdef list vs_item = [vs_pos,0]
	v_stack.append(vs_item)
	cdef long d = 1
#
#	iterate to the specified depth of modification
#
	cdef long deamidated = 0
	cdef long dm = 0
	cdef list m_list = []
	cdef tuple ml = ()
	cdef long mod_mass = 0
	cdef long mod_len = 0
	while d <= _depth:
#
#		generate a list of all possible combinations of "d" modifications
#
		m_list = list(itertools.combinations(master_list,d))
#
#		iterate through the modification combinations to create
#		the structures used to update the b and y ion lists
#		and supply the peptide mass change caused by the modifications
#
		for ml in m_list:
			deamidated = 0
			dm = 0
			vs_pos = {}
			for v in _mods:
				if v not in _pos:
					continue
				vs_pos[v] = [x[1] for x in ml if x[0] == v]
				mod_mass = _mods[v][0]
				mod_len = len(vs_pos[v])
				dm += mod_mass * mod_len
				if _mods[v][0] == 984:
					deamidated += mod_len
			if deamidated > 1:
				continue
			v_stack.append([vs_pos,dm])
		d += 1
	return v_stack

#
# method to locate possible variable modification sites in a sequence
#

cdef dict generate_vd(dict _mods,str _seq,str _pre):
	keep = False
	cdef dict v_pos = {}
	cdef long ls = len(_seq)
	cdef str v = ''
	bNt = True
	if _pre == 'G' and '[' in _mods:
		if _mods['['][0] == 57021:
			bNt = False
	for v in _mods:
		v_pos[v] = []
		if _mods.get(v) == 0:
			continue
		if v == '[' and bNt:
			v_pos[v] = [0]
			keep = True
		elif v == ']':
			v_pos[v] = [ls-1]
			keep = True
		if _seq.find(v) != -1:
			v_pos[v] = [x for x, y in enumerate(_seq) if y == v]
			keep = True
	if not keep:
		v_pos = {}
	return v_pos

#
# method to locate fixed modification sites in a sequence and create an array
# with this information for each set of modification states to be tested
#

cdef tuple generate_lpstack(dict _mods,str _seq,long _lp_len):
	cdef long lp_len = _lp_len
	cdef list lp_pos = []
	cdef list lp_total = []
	cdef long ls = len(_seq)
	cdef long lp = 0
	keep = False
	cdef long p_total = 0
	for lp in range(lp_len):
		p_pos = {}
		p_total = 0
		keep = False
		for p in _mods:
			p_pos[p] = []
			pms = _mods[p]
			if pms[lp] == 0:
				continue
			if p == '[':
				p_pos[p] = [0]
				p_total += pms[lp]
				keep = True
			elif p == ']':
				p_pos[p] = [ls-1]
				p_total += pms[lp]
				keep = True
			elif _seq.find(p) != -1:
				p_pos[p] = [x for x, y in enumerate(_seq) if y == p]
				p_total += len(p_pos[p])*pms[lp]
				keep = True
		if not keep:
			p_pos = {}
		lp_pos.append(p_pos)
		lp_total.append(p_total)
	return (lp_pos,lp_total)

#
# generate a JSON object from the kernel entry line (_l) and modify it
# using the information generated from the allowed modification lists
#

cdef tuple load_json(dict _l,dict _p_pos,dict _p_mods,list _b_mods,list _y_mods,long _lp,dict _vs_pos,dict _v_mods,double _fres):
	cdef dict jin = _l
	jin['mods'] = []
	if _p_pos:
		jin = update_ions(jin,_p_mods,_p_pos,_lp)
	if _vs_pos:
		jin = update_ions(jin,_v_mods,_vs_pos,0)
	if _b_mods:
		jin = update_bions(jin,_b_mods)
	if _y_mods:
		jin = update_yions(jin,_y_mods)
	cdef list ms = jin['bs']+jin['ys']
	if jin['pm'] > 1200:
		ms.extend([jin['bs'][-1]/2,jin['bs'][-2]/2,jin['bs'][-3]/2])
	cdef dict v = {}
	ms = [int(0.5+float(i)/_fres) for i in ms]
	cdef str j = ''
	for j in jin:
		if j == 'bs' or j == 'ys':
			continue
		v[j] = jin[j]
	return (v,ms)	

#
# method to update ion series based on a set of modifications specified by:
# _pos - the array of locations (_pos), 
# _mod - the array of modifications, &
# _lp - the position in _pos
#

cdef dict update_ions(dict _js,dict _mods,dict _pos,long _lp):
	cdef dict jin = _js
	cdef long t = len(jin['bs'])
	cdef list mod_tuples = []
	cdef long tmod = 0
	cdef long beg = jin['beg']
	cdef long a = 0
	cdef long delta = 0
	cdef str m = ''
	for m in _mods:
		if not _pos[m]:
			continue
		a = 0
		delta = 0
		pmod = _mods[m][_lp]
		for a in range(t):
			if a in _pos[m]:
				mod_tuples.append((beg+a,pmod))
				tmod += pmod
				delta += pmod
			if delta == 0:
				continue
			jin['bs'][a] += delta
		if t in _pos[m]:
			mod_tuples.append((beg+t,pmod))
			tmod += pmod
		a = 0
		delta = 0
		for a in range(t):
			if t-a in _pos[m]:
				delta += pmod
			if delta == 0:
				continue
			jin['ys'][a] += delta
	for tup in mod_tuples:
		jin['mods'].append({tup[0]:tup[1]})
	jin['pm'] += tmod
	return jin

#
# two ion series update functions that deal with modifications to either
# end of the sequence
# update_bions for N-terminal modifications
# update_yions for C-terminal modification
# Note: these could be handled by update_ions, but they are
#       broken out as separate methods for clarity and easier
#       debugging
#
cdef dict update_bions(_js,_bmods):
	cdef dict js = _js
	cdef long t = len(js['bs'])
	cdef dict mods = {}
	cdef long beg = js['beg']
	cdef list mod_tuples = []
	cdef long b = 0
	cdef long a = 0
	for b in _bmods:
		js['pm'] += b
		mod_tuples.append((beg,b))
		for a in range(t):
			js['bs'][a] += b
	for tup in mod_tuples:
		js['mods'].append({tup[0]:tup[1]})
	return js

cdef dict update_yions(dict _js,list _ymods):
	cdef dict js = _js
	cdef long t = len(js['ys'])
	cdef dict mods = {}
	cdef long end = js['end']
	cdef list mod_tuples = []
	cdef long b = 0
	cdef long a = 0
	for b in _ymods:
		js['pm'] += b
		mod_tuples.append((end,b))
		for a in range(t):
			js['ys'][a] += b
	for tup in mod_tuples:
		js['mods'].append({tup[0]:tup[1]})
	return js

#
# Two methods for the spectrum mass indexing system
# that uses a dictionary and binning to perform the matches
#

cdef tuple create_index(list _sp,double _r):
	cdef dict index = {}
	cdef list masses = []
	cdef long a = 0
	cdef long pm = 0
	cdef long m = 0
	cdef dict s = {}
	for s in _sp:
		m = s['pm']
		masses.append(m)
		pm = int(0.5 + float(m)/_r)
		if pm in index:
			index[pm].append(a)
		else:
			index[pm] = [a]
		if pm-1 in index:
			index[pm-1].append(a)
		else:
			index[pm-1] = [a]
		if pm+1 in index:
			index[pm+1].append(a)
		else:
			index[pm+1] = [a]
		a += 1
	return (index,masses)


cdef list get_spectra(_index,double _mass,double _r,list _slots = []):
	cdef long iv = int(0.5+_mass/_r)
	cdef list pms = []
	pms += _index.get(iv,[])
	cdef long s = 0
	for s in _slots:
		iv = int(0.5+(_mass+s)/_r)
		pms += _index.get(iv,[])
	return pms

