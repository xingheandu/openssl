#!/usr/bin/env perl

# ====================================================================
# Written by Andy Polyakov <appro@openssl.org> for the OpenSSL
# project. The module is, however, dual licensed under OpenSSL and
# CRYPTOGAMS licenses depending on where you obtain it. For further
# details see http://www.openssl.org/~appro/cryptogams/.
# ====================================================================

# March 2010
#
# The module implements "4-bit" GCM GHASH function and underlying
# single multiplication operation in GF(2^128). "4-bit" means that it
# uses 256 bytes per-key table [+128 bytes shared table]. Performance
# results are for streamed GHASH subroutine on UltraSPARC pre-Tx CPU
# and are expressed in cycles per processed byte, less is better:
#
#		gcc 3.3.x	cc 5.2		this assembler
#
# 32-bit build	81.4		43.3		12.6	(+546%/+244%)
# 64-bit build	20.2		21.2		12.6	(+60%/+68%)
#
# Here is data collected on UltraSPARC T1 system running Linux:
#
#		gcc 4.4.1			this assembler
#
# 32-bit build	566				50	(+1000%)
# 64-bit build	56				50	(+12%)
#
# I don't quite understand why difference between 32-bit and 64-bit
# compiler-generated code is so big. Compilers *were* instructed to
# generate code for UltraSPARC and should have used 64-bit registers
# for Z vector (see C code) even in 32-bit build... Oh well, it only
# means more impressive improvement coefficients for this assembler
# module;-) Loops are aggressively modulo-scheduled in respect to
# references to input data and Z.hi updates to achieve 12 cycles
# timing. To anchor to something else, sha1-sparcv9.pl spends 11.6
# cycles to process one byte on UltraSPARC pre-Tx CPU and ~24 on T1.
#
# October 2012
#
# Add VIS3 lookup-table-free implementation using polynomial
# multiplication xmulx[hi] and extended addition addxc[cc]
# instructions. 3.96/6.26x improvement on T3/T4 or in absolute
# terms 9.02/2.61 cycles per byte.

$bits=32;
for (@ARGV)     { $bits=64 if (/\-m64/ || /\-xarch\=v9/); }
if ($bits==64)  { $bias=2047; $frame=192; }
else            { $bias=0;    $frame=112; }

$output=shift;
open STDOUT,">$output";

$Zhi="%o0";	# 64-bit values
$Zlo="%o1";
$Thi="%o2";
$Tlo="%o3";
$rem="%o4";
$tmp="%o5";

$nhi="%l0";	# small values and pointers
$nlo="%l1";
$xi0="%l2";
$xi1="%l3";
$rem_4bit="%l4";
$remi="%l5";
$Htblo="%l6";
$cnt="%l7";

$Xi="%i0";	# input argument block
$Htbl="%i1";
$inp="%i2";
$len="%i3";

$code.=<<___ if ($bits==64);
.register	%g2,#scratch
.register	%g3,#scratch
___
$code.=<<___;
.section	".text",#alloc,#execinstr

.align	64
rem_4bit:
	.long	`0x0000<<16`,0,`0x1C20<<16`,0,`0x3840<<16`,0,`0x2460<<16`,0
	.long	`0x7080<<16`,0,`0x6CA0<<16`,0,`0x48C0<<16`,0,`0x54E0<<16`,0
	.long	`0xE100<<16`,0,`0xFD20<<16`,0,`0xD940<<16`,0,`0xC560<<16`,0
	.long	`0x9180<<16`,0,`0x8DA0<<16`,0,`0xA9C0<<16`,0,`0xB5E0<<16`,0
.type	rem_4bit,#object
.size	rem_4bit,(.-rem_4bit)

.globl	gcm_ghash_4bit
.align	32
gcm_ghash_4bit:
	save	%sp,-$frame,%sp
	ldub	[$inp+15],$nlo
	ldub	[$Xi+15],$xi0
	ldub	[$Xi+14],$xi1
	add	$len,$inp,$len
	add	$Htbl,8,$Htblo

1:	call	.+8
	add	%o7,rem_4bit-1b,$rem_4bit

.Louter:
	xor	$xi0,$nlo,$nlo
	and	$nlo,0xf0,$nhi
	and	$nlo,0x0f,$nlo
	sll	$nlo,4,$nlo
	ldx	[$Htblo+$nlo],$Zlo
	ldx	[$Htbl+$nlo],$Zhi

	ldub	[$inp+14],$nlo

	ldx	[$Htblo+$nhi],$Tlo
	and	$Zlo,0xf,$remi
	ldx	[$Htbl+$nhi],$Thi
	sll	$remi,3,$remi
	ldx	[$rem_4bit+$remi],$rem
	srlx	$Zlo,4,$Zlo
	mov	13,$cnt
	sllx	$Zhi,60,$tmp
	xor	$Tlo,$Zlo,$Zlo
	srlx	$Zhi,4,$Zhi
	xor	$Zlo,$tmp,$Zlo

	xor	$xi1,$nlo,$nlo
	and	$Zlo,0xf,$remi
	and	$nlo,0xf0,$nhi
	and	$nlo,0x0f,$nlo
	ba	.Lghash_inner
	sll	$nlo,4,$nlo
.align	32
.Lghash_inner:
	ldx	[$Htblo+$nlo],$Tlo
	sll	$remi,3,$remi
	xor	$Thi,$Zhi,$Zhi
	ldx	[$Htbl+$nlo],$Thi
	srlx	$Zlo,4,$Zlo
	xor	$rem,$Zhi,$Zhi
	ldx	[$rem_4bit+$remi],$rem
	sllx	$Zhi,60,$tmp
	xor	$Tlo,$Zlo,$Zlo
	ldub	[$inp+$cnt],$nlo
	srlx	$Zhi,4,$Zhi
	xor	$Zlo,$tmp,$Zlo
	ldub	[$Xi+$cnt],$xi1
	xor	$Thi,$Zhi,$Zhi
	and	$Zlo,0xf,$remi

	ldx	[$Htblo+$nhi],$Tlo
	sll	$remi,3,$remi
	xor	$rem,$Zhi,$Zhi
	ldx	[$Htbl+$nhi],$Thi
	srlx	$Zlo,4,$Zlo
	ldx	[$rem_4bit+$remi],$rem
	sllx	$Zhi,60,$tmp
	xor	$xi1,$nlo,$nlo
	srlx	$Zhi,4,$Zhi
	and	$nlo,0xf0,$nhi
	addcc	$cnt,-1,$cnt
	xor	$Zlo,$tmp,$Zlo
	and	$nlo,0x0f,$nlo
	xor	$Tlo,$Zlo,$Zlo
	sll	$nlo,4,$nlo
	blu	.Lghash_inner
	and	$Zlo,0xf,$remi

	ldx	[$Htblo+$nlo],$Tlo
	sll	$remi,3,$remi
	xor	$Thi,$Zhi,$Zhi
	ldx	[$Htbl+$nlo],$Thi
	srlx	$Zlo,4,$Zlo
	xor	$rem,$Zhi,$Zhi
	ldx	[$rem_4bit+$remi],$rem
	sllx	$Zhi,60,$tmp
	xor	$Tlo,$Zlo,$Zlo
	srlx	$Zhi,4,$Zhi
	xor	$Zlo,$tmp,$Zlo
	xor	$Thi,$Zhi,$Zhi

	add	$inp,16,$inp
	cmp	$inp,$len
	be,pn	`$bits==64?"%xcc":"%icc"`,.Ldone
	and	$Zlo,0xf,$remi

	ldx	[$Htblo+$nhi],$Tlo
	sll	$remi,3,$remi
	xor	$rem,$Zhi,$Zhi
	ldx	[$Htbl+$nhi],$Thi
	srlx	$Zlo,4,$Zlo
	ldx	[$rem_4bit+$remi],$rem
	sllx	$Zhi,60,$tmp
	xor	$Tlo,$Zlo,$Zlo
	ldub	[$inp+15],$nlo
	srlx	$Zhi,4,$Zhi
	xor	$Zlo,$tmp,$Zlo
	xor	$Thi,$Zhi,$Zhi
	stx	$Zlo,[$Xi+8]
	xor	$rem,$Zhi,$Zhi
	stx	$Zhi,[$Xi]
	srl	$Zlo,8,$xi1
	and	$Zlo,0xff,$xi0
	ba	.Louter
	and	$xi1,0xff,$xi1
.align	32
.Ldone:
	ldx	[$Htblo+$nhi],$Tlo
	sll	$remi,3,$remi
	xor	$rem,$Zhi,$Zhi
	ldx	[$Htbl+$nhi],$Thi
	srlx	$Zlo,4,$Zlo
	ldx	[$rem_4bit+$remi],$rem
	sllx	$Zhi,60,$tmp
	xor	$Tlo,$Zlo,$Zlo
	srlx	$Zhi,4,$Zhi
	xor	$Zlo,$tmp,$Zlo
	xor	$Thi,$Zhi,$Zhi
	stx	$Zlo,[$Xi+8]
	xor	$rem,$Zhi,$Zhi
	stx	$Zhi,[$Xi]

	ret
	restore
.type	gcm_ghash_4bit,#function
.size	gcm_ghash_4bit,(.-gcm_ghash_4bit)
___

undef $inp;
undef $len;

$code.=<<___;
.globl	gcm_gmult_4bit
.align	32
gcm_gmult_4bit:
	save	%sp,-$frame,%sp
	ldub	[$Xi+15],$nlo
	add	$Htbl,8,$Htblo

1:	call	.+8
	add	%o7,rem_4bit-1b,$rem_4bit

	and	$nlo,0xf0,$nhi
	and	$nlo,0x0f,$nlo
	sll	$nlo,4,$nlo
	ldx	[$Htblo+$nlo],$Zlo
	ldx	[$Htbl+$nlo],$Zhi

	ldub	[$Xi+14],$nlo

	ldx	[$Htblo+$nhi],$Tlo
	and	$Zlo,0xf,$remi
	ldx	[$Htbl+$nhi],$Thi
	sll	$remi,3,$remi
	ldx	[$rem_4bit+$remi],$rem
	srlx	$Zlo,4,$Zlo
	mov	13,$cnt
	sllx	$Zhi,60,$tmp
	xor	$Tlo,$Zlo,$Zlo
	srlx	$Zhi,4,$Zhi
	xor	$Zlo,$tmp,$Zlo

	and	$Zlo,0xf,$remi
	and	$nlo,0xf0,$nhi
	and	$nlo,0x0f,$nlo
	ba	.Lgmult_inner
	sll	$nlo,4,$nlo
.align	32
.Lgmult_inner:
	ldx	[$Htblo+$nlo],$Tlo
	sll	$remi,3,$remi
	xor	$Thi,$Zhi,$Zhi
	ldx	[$Htbl+$nlo],$Thi
	srlx	$Zlo,4,$Zlo
	xor	$rem,$Zhi,$Zhi
	ldx	[$rem_4bit+$remi],$rem
	sllx	$Zhi,60,$tmp
	xor	$Tlo,$Zlo,$Zlo
	ldub	[$Xi+$cnt],$nlo
	srlx	$Zhi,4,$Zhi
	xor	$Zlo,$tmp,$Zlo
	xor	$Thi,$Zhi,$Zhi
	and	$Zlo,0xf,$remi

	ldx	[$Htblo+$nhi],$Tlo
	sll	$remi,3,$remi
	xor	$rem,$Zhi,$Zhi
	ldx	[$Htbl+$nhi],$Thi
	srlx	$Zlo,4,$Zlo
	ldx	[$rem_4bit+$remi],$rem
	sllx	$Zhi,60,$tmp
	srlx	$Zhi,4,$Zhi
	and	$nlo,0xf0,$nhi
	addcc	$cnt,-1,$cnt
	xor	$Zlo,$tmp,$Zlo
	and	$nlo,0x0f,$nlo
	xor	$Tlo,$Zlo,$Zlo
	sll	$nlo,4,$nlo
	blu	.Lgmult_inner
	and	$Zlo,0xf,$remi

	ldx	[$Htblo+$nlo],$Tlo
	sll	$remi,3,$remi
	xor	$Thi,$Zhi,$Zhi
	ldx	[$Htbl+$nlo],$Thi
	srlx	$Zlo,4,$Zlo
	xor	$rem,$Zhi,$Zhi
	ldx	[$rem_4bit+$remi],$rem
	sllx	$Zhi,60,$tmp
	xor	$Tlo,$Zlo,$Zlo
	srlx	$Zhi,4,$Zhi
	xor	$Zlo,$tmp,$Zlo
	xor	$Thi,$Zhi,$Zhi
	and	$Zlo,0xf,$remi

	ldx	[$Htblo+$nhi],$Tlo
	sll	$remi,3,$remi
	xor	$rem,$Zhi,$Zhi
	ldx	[$Htbl+$nhi],$Thi
	srlx	$Zlo,4,$Zlo
	ldx	[$rem_4bit+$remi],$rem
	sllx	$Zhi,60,$tmp
	xor	$Tlo,$Zlo,$Zlo
	srlx	$Zhi,4,$Zhi
	xor	$Zlo,$tmp,$Zlo
	xor	$Thi,$Zhi,$Zhi
	stx	$Zlo,[$Xi+8]
	xor	$rem,$Zhi,$Zhi
	stx	$Zhi,[$Xi]

	ret
	restore
.type	gcm_gmult_4bit,#function
.size	gcm_gmult_4bit,(.-gcm_gmult_4bit)
___

{{{
# Straightforward 64-bits-at-a-time approach with pair of 128x64-bit
# multiplications followed by 64-bit reductions. While it might be
# suboptimal with regard to sheer amount of multiplications, other
# methods would require larger amount of 64-bit registers, which we
# don't have in 32-bit application. Also, they [alternative methods
# such as aggregated reduction] kind of thrive on fast 128-bit SIMD
# instructions and these are not option on SPARC...

($Xip,$Htable,$inp,$len)=map("%i$_",(0..3));

($xE1,$Hhi,$Hlo,$Rhi,$Rlo,$M0hi,$M0lo,$M1hi,$M1lo,$Zhi,$Zlo,$X)=
	(map("%g$_",(1..5)),map("%o$_",(0..5,7)));
($shl,$shr)=map("%l$_",(0..7));

$code.=<<___;
.globl	gcm_gmult_vis3
.align	32
gcm_gmult_vis3:
	save	%sp,-$frame,%sp

	ldx	[$Xip+8],$X		! load X.lo
	ldx	[$Htable-8], $Hlo	! load H
	ldx	[$Htable-16],$Hhi
	mov	0xE1,$xE1
	sllx	$xE1,57,$xE1

	xmulx	$X,$Hlo,$M0lo		! H�X.lo
	xmulxhi	$X,$Hlo,$M0hi
	xmulx	$X,$Hhi,$M1lo
	xmulxhi	$X,$Hhi,$M1hi
	ldx	[$Xip+0],$X		! load X.hi

	addcc	$M0lo,$M0lo,$M0lo	! (H�X.lo)<<1
	xor	$M0hi,$M1lo,$M1lo

	xmulx	$xE1,$M0lo,$Rlo		! res=Z.lo�(0xE1<<57)
	xmulxhi	$xE1,$M0lo,$Rhi

	addxccc	$M1lo,$M1lo,$Zlo	! Z=((H�X.lo)<<1)>>64
	addxc	$M1hi,$M1hi,$Zhi
	xor	$M0lo,$Zhi,$Zhi		! overflow bit from 0xE1<<57

	xmulx	$X,$Hlo,$M0lo		! H�X.hi
	xmulxhi	$X,$Hlo,$M0hi
	xmulx	$X,$Hhi,$M1lo
	xmulxhi	$X,$Hhi,$M1hi

	xor	$Rlo,$Zlo,$Zlo		! Z^=res
	xor	$Rhi,$Zhi,$Zhi

	addcc	$M0lo,$M0lo,$M0lo	! (H�X.lo)<<1
	xor	$Zlo, $M0lo,$M0lo
	xor	$M0hi,$M1lo,$M1lo

	xmulx	$xE1,$M0lo,$Rlo		! res=Z.lo�(0xE1<<57)
	xmulxhi	$xE1,$M0lo,$Rhi

	addxccc	$M1lo,$M1lo,$M1lo
	addxc	$M1hi,$M1hi,$M1hi

	xor	$M1lo,$Zhi,$Zlo		! Z=(Z^(H�X.hi)<<1)>>64
	xor	$M0lo,$M1hi,$Zhi	! overflow bit from 0xE1<<57

	xor	$Rlo,$Zlo,$Zlo		! Z^=res
	xor	$Rhi,$Zhi,$Zhi

	stx	$Zlo,[$Xip+8]		! save Xi
	stx	$Zhi,[$Xip+0]

	ret
	restore
.type	gcm_gmult_vis3,#function
.size	gcm_gmult_vis3,.-gcm_gmult_vis3

.globl	gcm_ghash_vis3
.align	32
gcm_ghash_vis3:
	save	%sp,-$frame,%sp

	ldx	[$Xip+0],$Zhi		! load X.hi
	ldx	[$Xip+8],$Zlo		! load X.lo
	and	$inp,7,$shl
	andn	$inp,7,$inp
	ldx	[$Htable-8], $Hlo	! load H
	ldx	[$Htable-16],$Hhi
	sll	$shl,3,$shl
	prefetch [$inp+63], 20
	mov	0xE1,$xE1
	sub	%g0,$shl,$shr
	sllx	$xE1,57,$xE1

.Loop:
	ldx	[$inp+8],$Rlo		! load *inp
	brz,pt	$shl,1f
	ldx	[$inp+0],$Rhi

	ldx	[$inp+16],$X		! align data
	srlx	$Rlo,$shr,$M0lo
	sllx	$Rlo,$shl,$Rlo
	sllx	$Rhi,$shl,$Rhi
	srlx	$X,$shr,$X
	or	$M0lo,$Rhi,$Rhi
	or	$X,$Rlo,$Rlo

1:
	add	$inp,16,$inp
	sub	$len,16,$len
	xor	$Rlo,$Zlo,$X
	prefetch [$inp+63], 20

	xmulx	$X,$Hlo,$M0lo		! H�X.lo
	xmulxhi	$X,$Hlo,$M0hi
	xmulx	$X,$Hhi,$M1lo
	xmulxhi	$X,$Hhi,$M1hi
	xor	$Rhi,$Zhi,$X

	addcc	$M0lo,$M0lo,$M0lo	! (H�X.lo)<<1
	xor	$M0hi,$M1lo,$M1lo

	xmulx	$xE1,$M0lo,$Rlo		! res=Z.lo�(0xE1<<57)
	xmulxhi	$xE1,$M0lo,$Rhi

	addxccc	$M1lo,$M1lo,$Zlo	! Z=((H�X.lo)<<1)>>64
	addxc	$M1hi,$M1hi,$Zhi
	xor	$M0lo,$Zhi,$Zhi		! overflow bit from 0xE1<<57

	xmulx	$X,$Hlo,$M0lo		! H�X.hi
	xmulxhi	$X,$Hlo,$M0hi
	xmulx	$X,$Hhi,$M1lo
	xmulxhi	$X,$Hhi,$M1hi

	xor	$Rlo,$Zlo,$Zlo		! Z^=res
	xor	$Rhi,$Zhi,$Zhi

	addcc	$M0lo,$M0lo,$M0lo	! (H�X.lo)<<1
	xor	$Zlo, $M0lo,$M0lo
	xor	$M0hi,$M1lo,$M1lo

	xmulx	$xE1,$M0lo,$Rlo		! res=Z.lo�(0xE1<<57)
	xmulxhi	$xE1,$M0lo,$Rhi

	addxccc	$M1lo,$M1lo,$M1lo
	addxc	$M1hi,$M1hi,$M1hi

	xor	$M1lo,$Zhi,$Zlo		! Z=(Z^(H�X.hi)<<1)>>64
	xor	$M0lo,$M1hi,$Zhi	! overflow bit from 0xE1<<57

	xor	$Rlo,$Zlo,$Zlo		! Z^=res
	brnz,pt	$len,.Loop
	xor	$Rhi,$Zhi,$Zhi

	stx	$Zlo,[$Xip+8]		! save Xi
	stx	$Zhi,[$Xip+0]

	ret
	restore
.type	gcm_ghash_vis3,#function
.size	gcm_ghash_vis3,.-gcm_ghash_vis3
___
}}}
$code.=<<___;
.asciz	"GHASH for SPARCv9/VIS3, CRYPTOGAMS by <appro\@openssl.org>"
.align	4
___


# Purpose of these subroutines is to explicitly encode VIS instructions,
# so that one can compile the module without having to specify VIS
# extentions on compiler command line, e.g. -xarch=v9 vs. -xarch=v9a.
# Idea is to reserve for option to produce "universal" binary and let
# programmer detect if current CPU is VIS capable at run-time.
sub unvis3 {
my ($mnemonic,$rs1,$rs2,$rd)=@_;
my %bias = ( "g" => 0, "o" => 8, "l" => 16, "i" => 24 );
my ($ref,$opf);
my %visopf = (	"addxc"		=> 0x011,
		"addxccc"	=> 0x013,
		"xmulx"		=> 0x115,
		"xmulxhi"	=> 0x116	);

    $ref = "$mnemonic\t$rs1,$rs2,$rd";

    if ($opf=$visopf{$mnemonic}) {
	foreach ($rs1,$rs2,$rd) {
	    return $ref if (!/%([goli])([0-9])/);
	    $_=$bias{$1}+$2;
	}

	return	sprintf ".word\t0x%08x !%s",
			0x81b00000|$rd<<25|$rs1<<14|$opf<<5|$rs2,
			$ref;
    } else {
	return $ref;
    }
}

foreach (split("\n",$code)) {
	s/\`([^\`]*)\`/eval $1/ge;

	s/\b(xmulx[hi]*|addxc[c]{0,2})\s+(%[goli][0-7]),\s*(%[goli][0-7]),\s*(%[goli][0-7])/
		&unvis3($1,$2,$3,$4)
	 /ge;

	print $_,"\n";
}

close STDOUT;
