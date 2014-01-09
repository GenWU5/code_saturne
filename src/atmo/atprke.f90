!-------------------------------------------------------------------------------

! This file is part of Code_Saturne, a general-purpose CFD tool.
!
! Copyright (C) 1998-2013 EDF S.A.
!
! This program is free software; you can redistribute it and/or modify it under
! the terms of the GNU General Public License as published by the Free Software
! Foundation; either version 2 of the License, or (at your option) any later
! version.
!
! This program is distributed in the hope that it will be useful, but WITHOUT
! ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
! FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
! details.
!
! You should have received a copy of the GNU General Public License along with
! this program; if not, write to the Free Software Foundation, Inc., 51 Franklin
! Street, Fifth Floor, Boston, MA 02110-1301, USA.

!-------------------------------------------------------------------------------

subroutine atprke &
!================

 ( nscal  ,                                                       &
   rtpa   , propce ,                                              &
   tinstk ,                                                       &
   smbrk  , smbre )

!===============================================================================
! FONCTION :
! --------
!  SPECIFIQUE AU CAS ATMOSPHERIQUE :
!  CALCUL DU TERME DE PRODUCTION LIEE A LA FLOTTABILITE :
!  G = G*GRAD(THETA)/PRDTUR/THETA
!-------------------------------------------------------------------------------
! ARGUMENTS
!__________________.____._____.________________________________________________.
! name             !type!mode ! role                                           !
!__________________!____!_____!________________________________________________!
! nscal            ! i  ! <-- ! total number of scalars                        !
! rtpa             ! ra ! <-- ! calculated variables at cell centers           !
!  (ncelet, *)     !    !     !  (at previous time step)                       !
! propce(ncelet, *)! ra ! <-- ! physical properties at cell centers            !
! tinstk(ncelet)   ! tr ! --> ! Implicit part of the buoyancy term (for k)     !
! smbrk(ncelet)    ! tr ! --> ! Explicit part of the buoyancy term (for k)     !
! smbre(ncelet)    ! tr ! --> ! Explicit part of the buoyancy term (for eps)   !
!__________________!____!_____!________________________________________________!

!     TYPE : E (ENTIER), R (REEL), A (ALPHANUMERIQUE), T (TABLEAU)
!            L (LOGIQUE)   .. ET TYPES COMPOSES (EX : TR TABLEAU REEL)
!     MODE : <-- donnee, --> resultat, <-> Donnee modifiee
!            --- tableau de travail
!-------------------------------------------------------------------------------
!===============================================================================

!===============================================================================
! Module files
!===============================================================================

use paramx
use numvar
use entsor
use cstnum
use cstphy
use optcal
use parall
use period
use ppppar
use ppthch
use ppincl
use mesh
use field
use atincl
use field_operator

!===============================================================================

implicit none

! Arguments
integer          nscal

double precision rtpa (ncelet,*)
double precision propce(ncelet,*)
double precision smbrk(ncelet), smbre(ncelet)
double precision tinstk(ncelet)

! Local variables
integer         iel
integer         ipcvto
integer         itpp , iqw
integer         ipcliq
integer         iccocg, inc
integer         iivar

double precision gravke, prdtur
double precision theta_virt
double precision qldia,qw
double precision xk, xeps, visct, ttke, rho

double precision dum
double precision, allocatable, dimension(:,:) :: grad
double precision, dimension(:), pointer :: cromo

!===============================================================================

!===============================================================================
! 1. Initialisation
!===============================================================================

! Allocate work arrays
allocate(grad(3,ncelet))

! Pointer to density and turbulent viscosity
call field_get_val_s(icrom, cromo)
ipcvto = ipproc(ivisct)
if(isto2t.gt.0) then
  if (iroext.gt.0) then
    call field_get_val_prev_s(icrom, cromo)
  endif
  if(iviext.gt.0) then
    ipcvto = ipproc(ivista)
  endif
endif

!===============================================================================
! 2. Calcul des derivees de la temperature potentielle
!===============================================================================

if (ippmod(iatmos).eq.1) then
  call dry_atmosphere()
elseif (ippmod(iatmos).eq.2) then
  call humid_atmosphere()
endif

! Deallocate work arrays
deallocate(grad)

return
contains

!**************************************************************************
!* repository of tactical functions/subroutines
!**************************************************************************
!--------------------------------------------------------------------------
!
!--------------------------------------------------------------------------

subroutine dry_atmosphere()

! computes the production term in case of dry atmosphere
! ie. when ippmod(iatmos) eq 1

! Computation of the gradient of the potential temperature

itpp = isca(iscalt)

! computational options:

iccocg = 1
inc = 1

iivar = itpp

! computes the turbulent production/destruction terms:
! dry atmo: (1/sigmas*theta)*(dtheta/dz)*gz

call field_gradient_scalar(ivarfl(iivar), 1, imrgra, inc,           &
                           iccocg,                                  &
                           grad)

! Production and gravity terms
! TINSTK=P+G et TINSTE = P + (1-CE3)*G

if (iscalt.gt.0.and.nscal.ge.iscalt) then
  prdtur = sigmas(iscalt)
else
  prdtur = 1.d0
endif

if (itytur.eq.2) then
  do iel = 1, ncel
    rho   = cromo(iel)
    visct = propce(iel,ipcvto)
    xeps = rtpa(iel,iep )
    xk   = rtpa(iel,ik )
    ttke = xk / xeps

    gravke = (grad(1,iel)*gx + grad(2,iel)*gy + grad(3,iel)*gz) &
           / (rtpa(iel,itpp)*prdtur)

    ! Implicit part (no implicit part for epsilon because the source
    ! term is positive)
    tinstk(iel) = tinstk(iel) + max(-rho*volume(iel)*cmu*ttke*gravke, 0.d0)

    ! Explicit part
    smbre(iel) = smbrk(iel) + visct*max(gravke, zero)
    smbrk(iel) = smbrk(iel) + visct*gravke

  enddo
endif
end subroutine dry_atmosphere

!--------------------------------------------------------------------------
!
!--------------------------------------------------------------------------

subroutine humid_atmosphere()

! computes the production term in case of humid atmosphere
! ie. when ippmod(iatmos) eq 2

implicit none
double precision pphy

double precision, dimension(:), allocatable :: etheta
double precision, dimension(:), allocatable :: eq
double precision, dimension(:), allocatable :: gravke_theta
double precision, dimension(:), allocatable :: gravke_qw

allocate(etheta(ncelet))
allocate(eq(ncelet))
allocate(gravke_theta(ncelet))
allocate(gravke_qw(ncelet))

! Computation of the gradient of the potential temperature

itpp = isca(iscalt)
iqw = isca(itotwt)
ipcliq = ipproc(iliqwt)

! compute the coefficients etheta,eq

do iel = 1, ncel
  ! calculate the physical pressure 'pphy'
  if (imeteo.eq.0) then
    call atmstd(xyzcen(3,iel),pphy,dum,dum)
  else
    call intprf (                                                 &
         nbmett, nbmetm,                                          &
         ztmet, tmmet, phmet, xyzcen(3,iel), ttcabs, pphy )
  endif
  qw = rtpa(iel,iqw) ! total water content
  qldia = propce(iel,ipcliq) ! liquid water content
  call etheq(pphy,rtpa(iel,itpp),qw,qldia,                      &
             nebdia(iel),nn(iel),etheta(iel),eq(iel))
enddo
! options for gradient calculation

iccocg = 1
inc = 1

iivar = itpp

! computes the turbulent production/destruction terms:
! humid atmo: (1/sigmas*theta_v)*(dtheta_l/dz)*gz

call field_gradient_scalar(ivarfl(iivar), 1, imrgra, inc,           &
                           iccocg,                                  &
                           grad)

! Production and gravity terms
! TINSTK = P + G et TINSTE = P + (1-CE3)*G

if(iscalt.gt.0.and.nscal.ge.iscalt) then
  prdtur = sigmas(iscalt)
else
  prdtur = 1.d0
endif

! store now the production term due to theta_liq in gravke_theta
if (itytur.eq.2) then
  do iel = 1, ncel
    qw = rtpa(iel,iqw) ! total water content
    qldia = propce(iel,ipcliq) ! liquid water content
    theta_virt = rtpa(iel,itpp)*(1.d0 + (rvsra - 1)*qw - rvsra*qldia)
    gravke = (grad(1,iel)*gx + grad(2,iel)*gy + grad(3,iel)*gz)            &
           / (theta_virt*prdtur)
    gravke_theta(iel) = gravke*etheta(iel)
  enddo
endif

! ----------------------------------------------------------------
! now gradient of humidity and it's associated production term
! ----------------------------------------------------------------

iivar = iqw

! computes the turbulent production/destruction terms:
! humid atmo: (1/sigmas*theta_v)*(dtheta_l/dz)*gz

call field_gradient_scalar(ivarfl(iivar), 1, imrgra, inc,           &
                           iccocg,                                  &
                           grad)

! Production and gravity terms
! TINSTK = P + G et TINSTE = P + (1-CE3)*G

if (iscalt.gt.0.and.nscal.ge.iscalt) then
  prdtur = sigmas(iscalt)
else
  prdtur = 1.d0
endif

! store the production term due to qw in gravke_qw

if (itytur.eq.2) then
  do iel = 1, ncel
    qw = rtpa(iel,iqw) ! total water content
    qldia = propce(iel,ipcliq) !liquid water content
    theta_virt = rtpa(iel,itpp)*(1.d0 + (rvsra - 1.d0)*qw - rvsra*qldia)
    gravke = (grad(1,iel)*gx + grad(2,iel)*gy + grad(3,iel)*gz)                 &
           / (theta_virt*prdtur)
    gravke_qw(iel) = gravke*eq(iel)
  enddo
endif

! Finalization
do iel = 1, ncel
  rho   = cromo(iel)
  visct = propce(iel,ipcvto)
  xeps = rtpa(iel,iep)
  xk   = rtpa(iel,ik)
  ttke = xk / xeps

  gravke = gravke_theta(iel) + gravke_qw(iel)

  ! Implicit part (no implicit part for epsilon because the source
  ! term is positive)
  tinstk(iel) = tinstk(iel) + max(-rho*volume(iel)*cmu*ttke*gravke, 0.d0)

  ! Explicit part
  smbre(iel) = smbrk(iel) + visct*max(gravke, zero)
  smbrk(iel) = smbrk(iel) + visct*gravke
enddo
end subroutine humid_atmosphere

end subroutine atprke
