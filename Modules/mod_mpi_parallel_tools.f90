!-----------module for definition of array dimensions and boundaries------------
module mpi_parallel_tools
#include <petsc/finclude/petscksp.h>
    use petscksp
    implicit none

!    include 'mpif.h'
    include "omp_lib.h"

    integer :: nx_start,    &   !first significant point in x-direction
               nx_end,      &   !last  significant point in x-direction
               ny_start,    &   !first significant point in y-direction
               ny_end           !last  significant point in y-direction

    integer :: bnd_x1,      &   !left   array boundary in x-direction
               bnd_x2,      &   !right  array boundary in x-direction
               bnd_y1,      &   !bottom array boundary in y-direction
               bnd_y2           !top    array boundary in y-direction

    integer :: rank, procs
    integer :: cart_comm
    integer, dimension(2) :: p_size, period, p_coord

    real*8 :: time_barotrop
    real*8 :: time_model_step, time_output
    real*8 :: time_sync

    contains

!-------------------------------------------------------------------------------
    subroutine start_parallel(ierr)
        implicit none
        integer :: ierr

        ierr = 0
        call mpi_init(ierr)
        !print *, "MPI Init, ierr = ", ierr

        ierr = 0
        call PetscInitialize(PETSC_NULL_CHARACTER, ierr)
        !print *, "PETSc Init, ierr = ", ierr

    end subroutine

    subroutine finalize_parallel(ierr)
        implicit none
        integer :: ierr

        call PETScFinalize(ierr)
        call mpi_finalize(ierr)

    end subroutine

!-------------------------------------------------------------------------------
    subroutine init_times
        implicit none
        time_model_step = 0.0d0
        time_barotrop = 0.0d0
        time_sync = 0.0d0
        time_output = 0.0d0
        return
    end subroutine

    subroutine print_times
        implicit none
        if (rank .eq. 0) then
            print *, "Time model step: ", time_model_step
            print *, "Time barotropic: ", time_barotrop
            print *, "Time sync: ", time_sync
            print *, "Time output: ", time_output
        endif
        return
    end subroutine

    subroutine start_timer(time)
        implicit none

        real*8, intent(inout) :: time
        integer :: ierr

        !time = mpi_wtime(ierr)
        time = mpi_wtime()
        return
    end subroutine

    subroutine end_timer(time)
        implicit none

        real*8, intent(inout) :: time
        real*8 :: outtime
        integer :: ierr

        !time = mpi_wtime(ierr) - time
        time = mpi_wtime() - time
        call mpi_allreduce(time, outtime, 1, mpi_real8,      &
                           mpi_max, cart_comm, ierr)
        time = outtime
        return
    end subroutine

!-------------------------------------------------------------------------------
    integer function get_rank_by_point(m, n)
        implicit none

        integer :: m, n
        integer :: flag_r, r, ierr

        flag_r = -1
        if (m >= nx_start .and. m <= nx_end) then
            if (n >= ny_start .and. n <= ny_end) then
                flag_r = rank
            endif
        endif

        call mpi_allreduce(flag_r, r, 1, mpi_integer,      &
                           mpi_max, cart_comm, ierr)

        get_rank_by_point = r
        return
    end function

!-------------------------------------------------------------------------------
    integer function check_p_coord(coord)
        implicit none
        integer, dimension(2), intent(in) :: coord

        check_p_coord = 0
!            write(*,*) coord,all(coord.ge.0),all((p_size-coord).ge.1)
!            print *, coord, p_size - coord, all((p_size-coord).ge.1)
        if (all(coord.ge.0) .and. all((p_size-coord).ge.1)) then
            check_p_coord = 1
        endif
        return
    end function

!-------------------------------------------------------------------------------
!-------------------------------------------------------------------------------
    subroutine directsync_real8(field, p_dist, xd1, xd2, yd1, yd2,             &
                                       p_src,  xs1, xs2, ys1, ys2, nz)
        implicit none
        integer :: nz
        real*8, intent(in out) :: field(bnd_x1:bnd_x2, bnd_y1:bnd_y2, nz)
        integer, dimension(2), intent(in) :: p_dist, p_src
        integer :: xd1, xd2, yd1, yd2 ! bound of array which sending to p_dist
        integer :: xs1, xs2, ys1, ys2 ! bound of array which recieving from p_src

        integer :: dist_rank, src_rank
        integer :: flag_dist, flag_src
        integer :: ierr, debg
        integer :: stat(mpi_status_size)

        debg = 0

        if ( ((xd1-xd2+1)*(yd1-yd2+1)) .ne. (xs1-xs2+1)*(ys1-ys2+1) ) then
            print *, "Error in sync arrays size!"
        endif

        flag_dist = check_p_coord(p_dist)
        flag_src = check_p_coord(p_src)

        if ( (flag_src .eq. 1) .and. (flag_dist .eq. 1) ) then
            call mpi_cart_rank(cart_comm, p_dist,dist_rank,ierr)
            call mpi_cart_rank(cart_comm, p_src, src_rank, ierr)

            call mpi_sendrecv(field(xd1:xd2, yd1:yd2, 1:nz),                          &
                              (xd2 - xd1 + 1)*(yd2 - yd1 + 1)*nz,                 &
                              mpi_real8, dist_rank, 1,                         &
                              field(xs1:xs2, ys1:ys2, 1:nz),                          &
                              (xs2 - xs1 + 1)*(ys2 - ys1 + 1)*nz,                 &
                              mpi_real8, src_rank, 1,                          &
                              cart_comm, stat, ierr)
!            print *, rank, "rsendecv", ierr
        else
            if (flag_src .eq. 1) then
                call mpi_cart_rank(cart_comm,p_src,src_rank,ierr)

                call mpi_recv(field(xs1:xs2, ys1:ys2, 1:nz),                          &
                              (xs2 - xs1 + 1)*(ys2 - ys1 + 1)*nz,                 &
                              mpi_real8, src_rank, 1,                          &
                              cart_comm, stat, ierr)
!                print *, rank, src_rank, "recv", xs1, xs2, ys1, ys2, field(xs1:xs2, ys1:ys2)
            endif

            if (flag_dist .eq. 1) then
                call mpi_cart_rank(cart_comm,p_dist,dist_rank,ierr)

                call mpi_send(field(xd1:xd2, yd1:yd2, 1:nz),                          &
                             (xd2 - xd1 + 1)*(yd2 - yd1 + 1)*nz,                  &
                             mpi_real8, dist_rank, 1,                          &
                             cart_comm, stat, ierr)
!                print *, rank, dist_rank, "send", xd1, xd2, yd1, yd2, field(xd1:xd2, yd1:yd2)
            endif
        endif

    end subroutine directsync_real8

!-------------------------------------------------------------------------------
    subroutine syncborder_real8(field, nz)
        implicit none
        integer :: nz
        real*8, intent(in out) :: field(bnd_x1:bnd_x2, bnd_y1:bnd_y2, nz)

        integer, dimension(2) :: p_dist, p_src
        real*8 :: time_count

        !call start_timer(time_count)
!------------------ send-recv in ny+ -------------------------------------------
        p_dist(1) = p_coord(1)
        p_dist(2) = p_coord(2) + 1
        p_src(1) = p_coord(1)
        p_src(2) = p_coord(2) - 1
        call directsync_real8(field, p_dist, nx_start, nx_end, ny_end, ny_end,       &
                                     p_src,  nx_start, nx_end, bnd_y1 + 1, bnd_y1 + 1, nz)
!------------------ send-recv in nx+ -------------------------------------------
        p_dist(1) = p_coord(1) + 1
        p_dist(2) = p_coord(2)
        p_src(1) = p_coord(1) - 1
        p_src(2) = p_coord(2)
        call directsync_real8(field, p_dist, nx_end, nx_end, ny_start, ny_end,       &
                                     p_src,  bnd_x1 + 1, bnd_x1 + 1, ny_start, ny_end, nz)
!------------------ send-recv in ny- -------------------------------------------
        p_dist(1) = p_coord(1)
        p_dist(2) = p_coord(2) - 1
        p_src(1) = p_coord(1)
        p_src(2) = p_coord(2) + 1
        call directsync_real8(field, p_dist, nx_start, nx_end, ny_start, ny_start,   &
                                     p_src,  nx_start, nx_end, bnd_y2 - 1, bnd_y2 - 1, nz)
!------------------ send-recv in nx- -------------------------------------------
        p_dist(1) = p_coord(1) - 1
        p_dist(2) = p_coord(2)
        p_src(1) = p_coord(1) + 1
        p_src(2) = p_coord(2)
        call directsync_real8(field, p_dist, nx_start, nx_start, ny_start, ny_end,   &
                                     p_src,  bnd_x2 - 1, bnd_x2 - 1, ny_start, ny_end, nz)


!------------------ Sync edge points (EP) --------------------------------------
!------------------ send-recv EP in nx+,ny+ ------------------------------------
         p_dist(1) = p_coord(1) + 1
         p_dist(2) = p_coord(2) + 1
         p_src(1) = p_coord(1) - 1
         p_src(2) = p_coord(2) - 1
         call directsync_real8(field, p_dist, nx_end, nx_end, ny_end, ny_end,   &
                                      p_src,  bnd_x1 + 1, bnd_x1 + 1, bnd_y1 + 1, bnd_y1 + 1, nz)
!------------------ send-recv EP in nx+,ny- ------------------------------------
         p_dist(1) = p_coord(1) + 1
         p_dist(2) = p_coord(2) - 1
         p_src(1) = p_coord(1) - 1
         p_src(2) = p_coord(2) + 1
         call directsync_real8(field, p_dist, nx_end, nx_end, ny_start, ny_start,   &
                                      p_src,  bnd_x1 + 1, bnd_x1 + 1, bnd_y2 - 1 , bnd_y2 - 1, nz)
!------------------ send-recv EP in nx-,ny- ------------------------------------
         p_dist(1) = p_coord(1) - 1
         p_dist(2) = p_coord(2) - 1
         p_src(1) = p_coord(1) + 1
         p_src(2) = p_coord(2) + 1
         call directsync_real8(field, p_dist, nx_start, nx_start, ny_start, ny_start,   &
                                      p_src,  bnd_x2 - 1, bnd_x2 - 1, bnd_y2 - 1, bnd_y2 - 1, nz)

!------------------ send-recv EP in nx-,ny+ ------------------------------------
         p_dist(1) = p_coord(1) - 1
         p_dist(2) = p_coord(2) + 1
         p_src(1) = p_coord(1) + 1
         p_src(2) = p_coord(2) - 1
         call directsync_real8(field, p_dist, nx_start, nx_start, ny_end, ny_end,  &
                                      p_src,  bnd_x2 - 1, bnd_x2 - 1, bnd_y1 + 1, bnd_y1 + 1, nz)

        !call end_timer(time_count)
        !time_sync = time_sync + time_count
        return
    end subroutine syncborder_real8

!-------------------------------------------------------------------------------
!-------------------------------------------------------------------------------
    subroutine directsync_real(field, p_dist, xd1, xd2, yd1, yd2,             &
                                       p_src,  xs1, xs2, ys1, ys2, nz)
        implicit none
        integer :: nz
        real*4, intent(in out) :: field(bnd_x1:bnd_x2, bnd_y1:bnd_y2, nz)
        integer, dimension(2), intent(in) :: p_dist, p_src
        integer :: xd1, xd2, yd1, yd2 ! bound of array which sending to p_dist
        integer :: xs1, xs2, ys1, ys2 ! bound of array which recieving from p_src

        integer :: dist_rank, src_rank
        integer :: flag_dist, flag_src
        integer :: ierr, debg
        integer :: stat(mpi_status_size)

        debg = 0

        if ( ((xd1-xd2+1)*(yd1-yd2+1)) .ne. (xs1-xs2+1)*(ys1-ys2+1) ) then
            print *, "Error in sync arrays size!"
        endif

        flag_dist = check_p_coord(p_dist)
        flag_src = check_p_coord(p_src)

        if ( (flag_src .eq. 1) .and. (flag_dist .eq. 1) ) then
            call mpi_cart_rank(cart_comm, p_dist,dist_rank,ierr)
            call mpi_cart_rank(cart_comm, p_src, src_rank, ierr)

            call mpi_sendrecv(field(xd1:xd2, yd1:yd2, 1:nz),                          &
                              (xd2 - xd1 + 1)*(yd2 - yd1 + 1)*nz,                 &
                              mpi_real4, dist_rank, 1,                         &
                              field(xs1:xs2, ys1:ys2, 1:nz),                          &
                              (xs2 - xs1 + 1)*(ys2 - ys1 + 1)*nz,                 &
                              mpi_real4, src_rank, 1,                          &
                              cart_comm, stat, ierr)
!            print *, rank, "rsendecv", ierr
        else
            if (flag_src .eq. 1) then
                call mpi_cart_rank(cart_comm,p_src,src_rank,ierr)

                call mpi_recv(field(xs1:xs2, ys1:ys2, 1:nz),                          &
                              (xs2 - xs1 + 1)*(ys2 - ys1 + 1)*nz,                 &
                              mpi_real4, src_rank, 1,                          &
                              cart_comm, stat, ierr)
!                print *, rank, src_rank, "recv", xs1, xs2, ys1, ys2, field(xs1:xs2, ys1:ys2)
            endif

            if (flag_dist .eq. 1) then
                call mpi_cart_rank(cart_comm,p_dist,dist_rank,ierr)

                call mpi_send(field(xd1:xd2, yd1:yd2, 1:nz),                          &
                             (xd2 - xd1 + 1)*(yd2 - yd1 + 1)*nz,                  &
                             mpi_real4, dist_rank, 1,                          &
                             cart_comm, stat, ierr)
!                print *, rank, dist_rank, "send", xd1, xd2, yd1, yd2, field(xd1:xd2, yd1:yd2)
            endif
        endif
        return
    end subroutine directsync_real

!-------------------------------------------------------------------------------
    subroutine syncborder_real(field, nz)
        implicit none
        integer :: nz
        real*4, intent(in out) :: field(bnd_x1:bnd_x2, bnd_y1:bnd_y2, nz)

        integer, dimension(2) :: p_dist, p_src

!------------------ send-recv in ny+ -------------------------------------------
        p_dist(1) = p_coord(1)
        p_dist(2) = p_coord(2) + 1
        p_src(1) = p_coord(1)
        p_src(2) = p_coord(2) - 1
        call directsync_real(field, p_dist, nx_start, nx_end, ny_end, ny_end,       &
                                     p_src,  nx_start, nx_end, bnd_y1 + 1, bnd_y1 + 1, nz)
!------------------ send-recv in nx+ -------------------------------------------
        p_dist(1) = p_coord(1) + 1
        p_dist(2) = p_coord(2)
        p_src(1) = p_coord(1) - 1
        p_src(2) = p_coord(2)
        call directsync_real(field, p_dist, nx_end, nx_end, ny_start, ny_end,       &
                                     p_src,  bnd_x1 + 1, bnd_x1 + 1, ny_start, ny_end, nz)
!------------------ send-recv in ny- -------------------------------------------
        p_dist(1) = p_coord(1)
        p_dist(2) = p_coord(2) - 1
        p_src(1) = p_coord(1)
        p_src(2) = p_coord(2) + 1
        call directsync_real(field, p_dist, nx_start, nx_end, ny_start, ny_start,   &
                                     p_src,  nx_start, nx_end, bnd_y2 - 1, bnd_y2 - 1, nz)
!------------------ send-recv in nx- -------------------------------------------
        p_dist(1) = p_coord(1) - 1
        p_dist(2) = p_coord(2)
        p_src(1) = p_coord(1) + 1
        p_src(2) = p_coord(2)
        call directsync_real(field, p_dist, nx_start, nx_start, ny_start, ny_end,   &
                                     p_src,  bnd_x2 - 1, bnd_x2 - 1, ny_start, ny_end, nz)


!------------------ Sync edge points (EP) --------------------------------------
!------------------ send-recv EP in nx+,ny+ ------------------------------------
         p_dist(1) = p_coord(1) + 1
         p_dist(2) = p_coord(2) + 1
         p_src(1) = p_coord(1) - 1
         p_src(2) = p_coord(2) - 1
         call directsync_real(field, p_dist, nx_end, nx_end, ny_end, ny_end,   &
                                      p_src,  bnd_x1 + 1, bnd_x1 + 1, bnd_y1 + 1, bnd_y1 + 1, nz)
!------------------ send-recv EP in nx+,ny- ------------------------------------
         p_dist(1) = p_coord(1) + 1
         p_dist(2) = p_coord(2) - 1
         p_src(1) = p_coord(1) - 1
         p_src(2) = p_coord(2) + 1
         call directsync_real(field, p_dist, nx_end, nx_end, ny_start, ny_start,   &
                                      p_src,  bnd_x1 + 1, bnd_x1 + 1, bnd_y2 - 1 , bnd_y2 - 1, nz)
!------------------ send-recv EP in nx-,ny- ------------------------------------
         p_dist(1) = p_coord(1) - 1
         p_dist(2) = p_coord(2) - 1
         p_src(1) = p_coord(1) + 1
         p_src(2) = p_coord(2) + 1
         call directsync_real(field, p_dist, nx_start, nx_start, ny_start, ny_start,   &
                                      p_src,  bnd_x2 - 1, bnd_x2 - 1, bnd_y2 - 1, bnd_y2 - 1, nz)

!------------------ send-recv EP in nx-,ny+ ------------------------------------
         p_dist(1) = p_coord(1) - 1
         p_dist(2) = p_coord(2) + 1
         p_src(1) = p_coord(1) + 1
         p_src(2) = p_coord(2) - 1
         call directsync_real(field, p_dist, nx_start, nx_start, ny_end, ny_end,  &
                                      p_src,  bnd_x2 - 1, bnd_x2 - 1, bnd_y1 + 1, bnd_y1 + 1, nz)

        return
    end subroutine syncborder_real

!-------------------------------------------------------------------------------
!-------------------------------------------------------------------------------
    subroutine directsync_int4(field, p_dist, xd1, xd2, yd1, yd2,             &
                                       p_src,  xs1, xs2, ys1, ys2, nz)
        implicit none
        integer :: nz
        integer*4, intent(in out) :: field(bnd_x1:bnd_x2, bnd_y1:bnd_y2, nz)
        integer, dimension(2), intent(in) :: p_dist, p_src
        integer :: xd1, xd2, yd1, yd2 ! bound of array which sending to p_dist
        integer :: xs1, xs2, ys1, ys2 ! bound of array which recieving from p_src

        integer :: dist_rank, src_rank
        integer :: flag_dist, flag_src
        integer :: ierr, debg
        integer :: stat(mpi_status_size)

        debg = 0

        if ( ((xd1-xd2+1)*(yd1-yd2+1)) .ne. (xs1-xs2+1)*(ys1-ys2+1) ) then
            print *, "Error in sync arrays size!"
        endif

        flag_dist = check_p_coord(p_dist)
        flag_src = check_p_coord(p_src)

        if ( (flag_src .eq. 1) .and. (flag_dist .eq. 1) ) then
            call mpi_cart_rank(cart_comm, p_dist,dist_rank,ierr)
            call mpi_cart_rank(cart_comm, p_src, src_rank, ierr)

            call mpi_sendrecv(field(xd1:xd2, yd1:yd2, 1:nz),                          &
                              (xd2 - xd1 + 1)*(yd2 - yd1 + 1)*nz,                 &
                              mpi_integer4, dist_rank, 1,                         &
                              field(xs1:xs2, ys1:ys2, 1:nz),                          &
                              (xs2 - xs1 + 1)*(ys2 - ys1 + 1)*nz,                 &
                              mpi_integer4, src_rank, 1,                          &
                              cart_comm, stat, ierr)
!            print *, rank, "rsendecv", ierr
        else
            if (flag_src .eq. 1) then
                call mpi_cart_rank(cart_comm,p_src,src_rank,ierr)

                call mpi_recv(field(xs1:xs2, ys1:ys2, 1:nz),                          &
                              (xs2 - xs1 + 1)*(ys2 - ys1 + 1)*nz,                 &
                              mpi_integer4, src_rank, 1,                          &
                              cart_comm, stat, ierr)
!                print *, rank, src_rank, "recv", xs1, xs2, ys1, ys2, field(xs1:xs2, ys1:ys2)
            endif

            if (flag_dist .eq. 1) then
                call mpi_cart_rank(cart_comm,p_dist,dist_rank,ierr)

                call mpi_send(field(xd1:xd2, yd1:yd2, 1:nz),                          &
                             (xd2 - xd1 + 1)*(yd2 - yd1 + 1)*nz,                  &
                             mpi_integer4, dist_rank, 1,                          &
                             cart_comm, stat, ierr)
!                print *, rank, dist_rank, "send", xd1, xd2, yd1, yd2, field(xd1:xd2, yd1:yd2)
            endif
        endif

    end subroutine directsync_int4

!-------------------------------------------------------------------------------
    subroutine syncborder_int4(field, nz)
        implicit none
        integer :: nz
        integer*4, intent(in out) :: field(bnd_x1:bnd_x2, bnd_y1:bnd_y2, nz)

        integer, dimension(2) :: p_dist, p_src

!------------------ send-recv in ny+ -------------------------------------------
        p_dist(1) = p_coord(1)
        p_dist(2) = p_coord(2) + 1
        p_src(1) = p_coord(1)
        p_src(2) = p_coord(2) - 1
        call directsync_int4(field, p_dist, nx_start, nx_end, ny_end, ny_end,       &
                                     p_src,  nx_start, nx_end, bnd_y1 + 1, bnd_y1 + 1, nz)
!------------------ send-recv in nx+ -------------------------------------------
        p_dist(1) = p_coord(1) + 1
        p_dist(2) = p_coord(2)
        p_src(1) = p_coord(1) - 1
        p_src(2) = p_coord(2)
        call directsync_int4(field, p_dist, nx_end, nx_end, ny_start, ny_end,       &
                                     p_src,  bnd_x1 + 1, bnd_x1 + 1, ny_start, ny_end, nz)
!------------------ send-recv in ny- -------------------------------------------
        p_dist(1) = p_coord(1)
        p_dist(2) = p_coord(2) - 1
        p_src(1) = p_coord(1)
        p_src(2) = p_coord(2) + 1
        call directsync_int4(field, p_dist, nx_start, nx_end, ny_start, ny_start,   &
                                     p_src,  nx_start, nx_end, bnd_y2 - 1, bnd_y2 - 1, nz)
!------------------ send-recv in nx- -------------------------------------------
        p_dist(1) = p_coord(1) - 1
        p_dist(2) = p_coord(2)
        p_src(1) = p_coord(1) + 1
        p_src(2) = p_coord(2)
        call directsync_int4(field, p_dist, nx_start, nx_start, ny_start, ny_end,   &
                                     p_src,  bnd_x2 - 1, bnd_x2 - 1, ny_start, ny_end, nz)


!------------------ Sync edge points (EP) --------------------------------------
!------------------ send-recv EP in nx+,ny+ ------------------------------------
         p_dist(1) = p_coord(1) + 1
         p_dist(2) = p_coord(2) + 1
         p_src(1) = p_coord(1) - 1
         p_src(2) = p_coord(2) - 1
         call directsync_int4(field, p_dist, nx_end, nx_end, ny_end, ny_end,   &
                                      p_src,  bnd_x1 + 1, bnd_x1 + 1, bnd_y1 + 1, bnd_y1 + 1, nz)
!------------------ send-recv EP in nx+,ny- ------------------------------------
         p_dist(1) = p_coord(1) + 1
         p_dist(2) = p_coord(2) - 1
         p_src(1) = p_coord(1) - 1
         p_src(2) = p_coord(2) + 1
         call directsync_int4(field, p_dist, nx_end, nx_end, ny_start, ny_start,   &
                                      p_src,  bnd_x1 + 1, bnd_x1 + 1, bnd_y2 - 1 , bnd_y2 - 1, nz)
!------------------ send-recv EP in nx-,ny- ------------------------------------
         p_dist(1) = p_coord(1) - 1
         p_dist(2) = p_coord(2) - 1
         p_src(1) = p_coord(1) + 1
         p_src(2) = p_coord(2) + 1
         call directsync_int4(field, p_dist, nx_start, nx_start, ny_start, ny_start,   &
                                      p_src,  bnd_x2 - 1, bnd_x2 - 1, bnd_y2 - 1, bnd_y2 - 1, nz)

!------------------ send-recv EP in nx-,ny+ ------------------------------------
         p_dist(1) = p_coord(1) - 1
         p_dist(2) = p_coord(2) + 1
         p_src(1) = p_coord(1) + 1
         p_src(2) = p_coord(2) - 1
         call directsync_int4(field, p_dist, nx_start, nx_start, ny_end, ny_end,  &
                                      p_src,  bnd_x2 - 1, bnd_x2 - 1, bnd_y1 + 1, bnd_y1 + 1, nz)

        return
    end subroutine syncborder_int4

endmodule mpi_parallel_tools
!---------------------end module for definition of array dimensions and boundaries-----------------
